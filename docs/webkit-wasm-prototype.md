# Runtime ARM64 translation through WebKit

This prototype generates WebAssembly bytes from ARM64 instruction words at
runtime and executes them in a Web Worker in `WKWebView`. WebKit compiles the
guest block. The worker contains no ARM64 interpreter and has no Swift imports
in its execution loop: its Wasm module imports only linear memory.

The approach was investigated using
[WasmWebViewRuntime](https://github.com/adammharris/WasmWebViewRuntime). This
prototype uses a small purpose-built block-execution bridge, with no new WASI
dependency or copied third-party runtime. Existing guest boot backends retain
their current execution paths.

## What works

- Existing native ARM64 decoder validates words before the Swift Wasm emitter
  selects its supported subset.
- ADD/SUB immediate without flags, move-wide, unshifted logical operations,
  scalar unsigned loads/stores, NOP and a terminal B backedge are translated.
- Guest registers, SP, PC, PSTATE, retirement counter and flat guest RAM remain
  in worker-owned Wasm memory. No native process crossings occur per operation.
- A block-count budget bounds the compiled loop, including the actual guest
  backedge. Reset and three short warmups precede three measured executions.
- 64-bit addresses are checked before conversion to Wasm32 indices. CPU state
  is outside the guest RAM window. Out-of-range access and writes overlapping
  the immutable translated block trap before committing the memory operation.
- Cancellation destroys the worker's page; a subsequent run creates a fresh
  worker. CLI differential tests verify cancellation and restart.

## Verified JIT activity

Both macOS and iOS 26.2 Simulator executed runtime-generated guest modules and
matched native reference registers, PC, PSTATE, retirement count and sampled RAM.

An iOS WebContent process sample captured:

```text
ipint_extern_loop_osr
JSC::Wasm::BBQPlan::work()
JSC::Wasm::BBQJITImpl::BBQJIT::addI64Add(...)
JSC::Wasm::OMGPlan::work()
JSC::Wasm::OMGIRGenerator::addBranch(...)
```

The worker's execution stack also contains generated-code addresses outside
loaded binaries. Together these show Wasm tier-up/JIT compilation and native
generated-code execution for the workload. Exact executing tier is not exposed
by a public WebKit API. The app neither requests a native JIT entitlement nor
uses private WebKit controls. This was not tested on a physical iPhone; JIT-less
WebKit configurations may behave differently. A `vmmap` attempt on the Simulator
content process failed to obtain DYLD information and is not used as evidence.

Local ignored artifacts: `.build/wasm-ios-webcontent-30182.sample.txt`,
`.build/wasm-webcontent-27588.sample.txt`, `.build/wasm-prototype-ios-report.json`,
and `.build/wasm-flat-macos-report.json`.

## Measured loop, not an Android boot benchmark

The five-instruction guest loop is ADD X0; STR X0; LDR X2; EOR X3; B start.
Each round retires 500 million guest instructions, including the guest branch.
Initial X0 wraps through zero. Native and Wasm results match exactly.

| Host | Native C reference | Wasm measured rounds | Wasm median |
| --- | --- | --- | --- |
| Mac | 3726.18 ms | 998, 1004, 993 ms | 998 ms |
| iOS Simulator | 4231.04 ms | 1048, 1065, 1043 ms | 1048 ms |

The baseline calls the existing cached native C interpreter directly with flat
64 KiB RAM and no MMU, assembly interpreter, AOT, or Swift instruction fallback.
This corrects the initial comparison against an MMU-backed VM. An additional
VM/MMU fixture independently verifies the flat baseline's state. One native run
is compared with three warmed Wasm rounds; setup/reset/compile are excluded from
execution timing. Compilation is reported separately and can round to 0 ms
because WebKit reduces clock resolution in this origin.

This is roughly a 3.7–4.0x improvement on a small, favorable loop. It does not
predict Android boot speed or physical-device performance. The JIT may eliminate
redundant guest operations while preserving their observable state.

## Run

On macOS, from the repository root:

```sh
swift run wasm-prototype --self-test
swift run wasm-prototype --blocks 100000000
```

The CLI attaches a small WebView window, runs the actual guest code and emits
JSON. `--self-test` runs 28 runtime/reference, overflow, SP/ZR, unaligned memory,
high-address/bounds/code-write trap and cancellation/restart cases.

The main iOS app's boot picker has a **WebKit / Wasm execution prototype** button.
Its prototype screen attaches the WebView visibly, shows a native comparison and
raw results, and writes `Documents/wasm-prototype-report.json`.
`PINECONE_WASM_PROTOTYPE=1` opens this screen directly. Optional
`PINECONE_WASM_PROTOTYPE_BLOCKS` selects up to 100 million blocks per round;
the default is two million. The normal app does not select this backend for
either Linux guest.

A separate **Pinecone Wasm** app is installed in the iPhone 17 Pro Simulator with
bundle ID `me.gmoran.pinecone.wasm-prototype`. It opens this screen directly even
without launch environment variables. The normal Pinecone installation and its
guest disks were preserved. This small test build excludes guest images and
optional VirGL frameworks.

The test build uses the normal Xcode project/scheme, with:

```text
PRODUCT_BUNDLE_IDENTIFIER=me.gmoran.pinecone.wasm-prototype
CODE_SIGNING_ALLOWED=NO
PINECONE_EMBED_VIRGL=0
EXCLUDED_SOURCE_FILE_NAMES=Image initramfs-minimal-ttyinit.cpio rootfs.ext4 rootfs.ext4.sha256
```

Its separate derived-data directory is `.build/wasm-prototype/DerivedData`.
The unsigned Simulator product's display name was set to Pinecone Wasm after
building; this is not a signing/distribution recipe for a physical device.

## Remaining work

This is a single-worker, 64 KiB flat-RAM experiment, not a full CPU/backend:
no MMU/page walking, interrupts, arbitrary control flow, SIMD/crypto, devices,
disk/image streaming, graphics bridge or interpreter fallback inside Wasm.
Stores to the translated code trap rather than invalidate/recompile. WebKit
capabilities report no SharedArrayBuffer/cross-origin isolation in the current
custom-scheme setup. Shared-RAM vCPUs and actual 1–2 GiB device memory capacity
remain unproven.

A bootable backend needs the CPU/MMU and fallback interpreter together inside
the worker, runtime translation of larger regions, precise service exits and
code invalidation. Native disk/display/input traffic must be batched; per-load
calls across the WebKit process boundary would lose the benefit.

Validation: the iOS Simulator build succeeds, 28 actual WebKit execution cases
pass, and the full Swift suite reports 786 tests, zero failures (two expected
skips when assembly/AOT test flags are enabled).
