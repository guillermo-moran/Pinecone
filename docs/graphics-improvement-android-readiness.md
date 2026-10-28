# Graphics improvement and Android readiness

Date: 2026-10-26. Scope: native graphics agent only. No guest rebuild,
Simulator launch/install, integrated Xcode build, public header/API change,
executor/memory change, JIT, QEMU, Swift interpreter fallback, or runtime
threshold/default change. Pre-existing dirty and untracked work is preserved.

## Captured baseline

Before the first production edit, copied the working-tree framebuffer source
(including the pre-existing glyph optimization) to:

`/tmp/arm64viz-graphics-identity.Y1hUvB/ARM64VizFramebuffer.before.c`

Both files then had SHA-256:
`8144ba51e36ab234d1ecae99560f9d6f1a835366dd207c438dc1a20c9af15ce3`.

Do not use `git show HEAD` as the performance baseline: it omits pre-existing
work. Keep the captured file for the parent's serial rerun.

## Inspection and chosen change

Inspection of the current working tree found:

- Guest Pixman records can carry the bilinear flag with no transform:
  `pinecone_source_geometry_locked` sets the filter flag before returning
  identity geometry. This is a reachable protocol case, not a new capability.
- Native unmasked SRC/OVER in `executeParavirtual2DInNativeCore` chooses the
  bilinear entry points before checking equal source/destination extents.
  Those entry points previously sampled and blended every pixel through the
  scalar bilinear loop, even for exact 1:1 copies.
- Metal already batches up to 64 commands with dependency barriers. Physical
  devices use shared no-copy buffers; the Simulator path uploads missing regions
  and copies dirty destination rectangles back before reporting completion.
- Input synchronization already deduplicates regions within one submission.
  Fragmented read-only backing gets private per-submission host mirrors; writable
  resources in an ordered batch share the destination mirror. These rules must
  not be replaced by a cross-submission cache without guest-write tracking.
- In-flight copy buffers are isolated; command completion retains the prepared
  resource state through finish/writeback. Resource reservations and reset drain
  govern when unref/reuse may proceed. The optimization changes none of this.
- Scanout flush already uses exact pending damage and changed-tile comparison.
  Published frame slots preserve held leases, and reused slots catch up on damage.
  Eliminating those copies without retaining equivalent ownership would be unsafe.

Only `Sources/ARM64VizNative/ARM64VizFramebuffer.c` changes production behavior.
The two bilinear entry points now select existing copy/OVER routines when both
extents match and the overflow-checked source/destination spans are disjoint.
At 1:1 pixel centers both fractional weights are zero, so the sampled value is
the original pixel exactly. OVER retains the existing integer divide-by-255
rounding and saturating addition, including non-premultiplied input behavior.
The OVER routine uses its existing NEON implementation where available.

Aliases retain the original sequential scalar semantics. Scaling in either
dimension retains the sampler. Masked operations, packed A8, component alpha,
glyph paths, clipping, format normalization, transforms, synchronization,
publication, guest-write notification, and accelerator eligibility are unchanged.
The pre-existing span helper is now available outside the NEON conditional;
there is no new public API or allocation.

## Exact regression coverage

New C regression:

- Full-buffer comparisons, including padding/canaries and source immutability.
- Every source alpha, 12 widths spanning SIMD tails, all 16 byte alignments,
  nonzero source/destination origins, premultiplied and saturating inputs.
- 266 scaled cases, including one-dimensional changes, that must retain the
  generic path; 128 forward/backward/identical alias cases.
- Invalid null, zero-size, overflowing coordinates, and short-stride requests
  must fail without modifying output.
- 512 independent Pixman bilinear identity cases; 512 comparisons to the actual
  captured baseline when supplied. No pixel tolerance is used.

Results on arm64 macOS, Apple clang 17.0.0, Pixman 0.42.2:

- Optimized: **7,572 exact cases passed**, including baseline comparisons.
- UBSan: **7,060 exact cases passed**, no diagnostics (baseline library omitted).
- Existing glyph suite: **67,258 cases passed**, normal and UBSan, preserving
  the pre-existing glyph specialization.
- The first combined ASan/UBSan run produced no output and was interrupted.
  ASan is **unverified**, not passed. Set `GRAPHICS_IDENTITY_SANITIZERS=address,undefined`
  to retry outside the restricted environment; default sanitizer is UBSan.
- Existing standalone Metal differential compiled its direct-mode harness but
  exited with **"Metal is unavailable"**. No hardware fence, device Metal, or
  Simulator-copy result is claimed from that attempt.

`GraphicsIdentityTests.swift` adds protocol-level tests for exact SRC/OVER
pixels on contiguous and fragmented backing, full 64-bit fence/context echo,
unchanged source, completion-before-CPU-read, no premature scanout publication,
immutable old frame leases across unref/reset/reuse, and error-then-valid recovery.
The standalone integration runner also includes the existing GPU concurrency
suite covering asynchronous fences, resource hazards, private source mirrors,
reset, and rejection. It links existing Swift build objects and a freshly
compiled framebuffer object; it is preliminary evidence, not a current-source
integrated rebuild. Parent must rerun after rebuilding current sources.

Local integration status: the new tests and runner compiled, but linking against
the existing object directory failed because `ARM64VizNativeExtensions.c.o`
references missing `_avz_native_decode_instruction_legacy`. No replacement native
objects or full rebuild were attempted. **The two new Swift tests have not run.**
The existing prebuilt test bundle separately passed all **12
GPUCommandConcurrencyTests**, zero failures, in **1.501 seconds**. That bundle
predates this change: this is baseline fence/lifetime evidence only, not a claim
that the new framebuffer is integrated. Temporary compiler caches from failed
attempts were removed; the runner now cleans its uniquely created module cache.

## Initial measurements

These are native raster **microbenchmarks**, not input-to-display/UI latency.
Five agents were active and concurrent compilation can distort absolute times.
The executable alternates baseline/candidate order across nine rounds and reports
median microseconds per call; both versions compile at `-O3` in the same process.
The baseline is dynamically loaded from the captured dirty-tree file.

Second run, `/tmp/arm64viz-graphics-identity-test.VpbqTC/identity.log`:

| Operation | Pixels | Baseline us | Candidate us | Ratio |
| --- | ---: | ---: | ---: | ---: |
| SRC | 64x32 | 14.701 | 0.166 | 88.48x |
| SRC | 128x128 | 103.348 | 1.364 | 75.75x |
| SRC | 400x480 | 1208.522 | 11.478 | 105.29x |
| SRC | 800x960 | 4867.375 | 57.125 | 85.21x |
| OVER | 64x32 | 16.566 | 0.760 | 21.81x |
| OVER | 128x128 | 136.964 | 6.012 | 22.78x |
| OVER | 400x480 | 1621.696 | 69.870 | 23.21x |
| OVER | 800x960 | 6901.875 | 310.625 | 22.22x |

Iterations per round: 1,956 / 247 / 23 / 8, respectively. First run ratios:
SRC 61.30-116.01x; OVER 22.35-23.71x. Small sizes are below the normal device
Metal threshold. Large sizes measure the existing native fallback path, not a
reason to disable Metal. Actual hit frequency has not been measured in the UI;
masked/scaled operations and accepted Metal work receive no benefit.

## Reproduction

Run from `/Users/gmoran/Documents/Projects/arm64viz`:

```sh
bash scripts/run-graphics-identity-regressions.sh \
  /tmp/arm64viz-graphics-identity.Y1hUvB/ARM64VizFramebuffer.before.c
bash scripts/run-host-raster-glyph-regressions.sh
bash scripts/run-graphics-identity-integration.sh
env TMPDIR=/tmp/arm64viz-graphics-identity.Y1hUvB \
  bash scripts/run-metal-compositor-differential.sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest ARM64VizCoreTests.GPUCommandConcurrencyTests \
  .build/arm64-apple-macosx/debug/arm64vizPackageTests.xctest
git diff --check -- Sources/ARM64VizNative/ARM64VizFramebuffer.c
```

The new scripts use unique small temporary directories, never the project's
SwiftPM scratch directory. `GRAPHICS_IDENTITY_WORKDIR` and
`GRAPHICS_INTEGRATION_WORKDIR` override outputs. The integration script requires
an existing macOS debug build (`GRAPHICS_EXISTING_BUILD` can override its path);
it does not invoke SwiftPM. Do not run it while the parent is replacing those
objects. Parent owns integrated native-only Simulator smoke and serial timings.
After the parent rebuild, run `GraphicsIdentityTests` and
`GPUCommandConcurrencyTests` through the normal test runner too.

## Android gaps and integration boundary

The existing `submit3D` opcode routes **Pinecone's proprietary bounded 2D
protocol**, identified by `PN2D`, into Pixman-style native/Metal composites.
It is not a general 3D stream, EGL/GLES implementation, complete Android GPU
driver, or evidence of Waydroid support. Accelerating the current path does not
provide shader execution, GL contexts, or Android buffer sharing.

Missing integration work, based on this repository's current graphics boundary:

1. **EGL/GLES:** a negotiated guest driver/transport for contexts, surfaces,
   extensions, shader/program objects, textures, renderbuffers, draw state,
   readback, context loss, and error propagation. Do not interpret generic
   virgl/gfxstream/Venus payloads as PN2D. Capabilities must match the selected
   guest userspace driver and the host decoder, with strict bounds validation.
2. **Allocation/import:** Android allocator/mapper integration for usage flags,
   shareable native handles, format/stride/plane metadata, and CPU lock/unlock.
   Current attached physical backing and linear BGRA/A8 storage do not establish
   DMA-BUF/modifier import, EGLImage/AHardwareBuffer interoperability, YUV, or
   protected-content semantics. A guest handle must never become an unchecked
   host pointer. BufferQueue passes handles between producer/consumer owners;
   it is not a per-frame pixel-copy API. See
   [AOSP BufferQueue and Gralloc](https://source.android.com/docs/core/graphics/arch-bq-gralloc).
3. **Fences/coherence:** bridge guest kernel synchronization to host GPU
   completion and buffer ownership: acquire-before-use, release-after-last-use,
   ordered error completion, cancellation/reset, and CPU mapping visibility.
   The current virtio fence ID/used-ring response is not an Android native fence
   FD import/export implementation. Android explicit synchronization passes
   dependencies across process/driver boundaries, including native fence EGL
   integration. See [AOSP synchronization](https://source.android.com/docs/core/graphics/sync).
4. **Presentation:** SurfaceFlinger/HWC integration needs a defined display and
   composition contract, present/release fences, vsync, damage, rotation,
   colorspace, and buffer lifetime during display. Immutable host snapshots are
   useful output infrastructure but do not implement that Android HAL contract.

A credible boundary is a **separate, negotiated graphics backend** adjacent to
the PN2D dispatch: validated guest context/resource commands enter an established
API translator; it returns completed resources and explicit fence/error events
to the existing ownership/dirty/publication machinery. Gfxstream is an example
of a guest/host API serialization project, not a drop-in Metal backend for this
app. Its [upstream overview](https://android.googlesource.com/platform/hardware/google/gfxstream/+/refs/heads/main/README.md)
documents GLES/RenderControl generation and guest-to-host transport. Selecting
and validating a Metal-capable translation layer, its iOS support/build/runtime
constraints, and the guest driver remains a separate feasibility project.

First milestones should be negotiated capability rejection, offscreen exact
readback with CPU coherence, cross-context buffer/fence reuse and destruction,
reset/error tests, then a gralloc-backed EGL surface and actual SurfaceFlinger
presentation. Require applicable EGL/GLES conformance tests and frame comparison
before advertising capabilities. No Android or Waydroid readiness claim is
made by this change.
