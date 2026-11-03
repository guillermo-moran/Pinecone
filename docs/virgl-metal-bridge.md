# Optional VirGL / ANGLE Metal renderer

The custom VirtIO GPU can now accept standard VirGL 3D commands alongside its
existing Alpine paravirtual 2D protocol. The host renderer uses a dedicated
thread, ANGLE GLES contexts explicitly backed by Metal, and virglrenderer's
embedding API. It does not use another emulator or a hypervisor.

## Reused paths

- Existing VirtIO MMIO/PCI transport, queue ordering, resource hazard gate,
  response/fence headers, reset serialization, and interrupts.
- Existing scanout storage, immutable frame publication, dirty comparison,
  GuestDisplaySurface, and UIKit touch input.
- The installed Android image's existing virtio DRM and Mesa/VirGL stack.
  Read-only inspection found VirGL in vendor `libgallium_dri.so`; its vendor
  init configuration already supports the `mesa` hardware profile. A derived
  guest disk adds the missing SELinux GPU sysfs label described below; no ROM
  build is required.

The native bridge loads four application-local frameworks: ANGLE GLESv2/EGL,
libepoxy, and virglrenderer. Capabilities are exposed only after successful
renderer initialization. Default builds/runs retain the established 2D path.
The VM must explicitly opt in with `enableVirGL`; the Android UI and CLI paths
do so, while Alpine keeps the 2D device even when `PINECONE_VIRGL=1` remains in
the host environment. Enabling VirGL implicitly for every GPU changed Alpine's
negotiated driver path and caused invalid-resource errors and a black monitor.
The isolation fix was verified in the simulator by initializing Android's Metal
renderer, switching to Alpine in the same process with the environment flag
still set, and observing Phosh render again with `virglEnabled: 0`.

Implemented protocol operations include capset discovery, context lifecycle,
resource creation/destruction, context resource attachment, guest backing,
2D/3D transfers, command submission, scanout and flush. Context-init timeline
rings, blobs, Venus/Vulkan, EDID and shared host memory are not advertised.
Guest backing uses bounded private snapshots; partial readbacks preserve guest
bytes outside the transferred region. Transfer-from-host uses the normal guest
memory write path so dirty/coherency tracking remains authoritative.

Backing synchronization also covers `TRANSFER3D` and `COPY_TRANSFER3D` packets
embedded in a VirGL submission. Mesa uses these to upload vertex and texture
data after attaching backing. The bridge validates packet boundaries, refreshes
only referenced snapshots before submission, and copies requested readbacks to
guest RAM after completion, preserving untouched backing bytes. Handling only
the separate VirtIO transfer requests left embedded uploads reading zeros and
produced an empty scanout despite successful shader submission.

Submissions currently finish actual host GPU work before the fenced virtqueue
reply. This is conservative synchronous fencing, not an asynchronous or
zero-copy implementation. Scanout-compatible textures are read back and enter
the existing display path. Shader execution is on the host GPU, but copies and
guest framework CPU work remain.

Published frame slots have independent lease bookkeeping. Metal completion
callbacks can release the final display frame owner without acquiring the GPU
device lock. Sharing that lock caused a real simulator deadlock: guest submission
held it while waiting for ANGLE/Metal completion, whose shared completion queue
was blocked releasing a display lease. A regression models this completion
dependency and verifies lease release while a renderer submission is blocked.

## Build on the Mac

Apple's offline Metal compiler component is required:

```sh
xcodebuild -downloadComponent MetalToolchain
sh scripts/graphics/build-renderer-dependencies.sh iphonesimulator
xcodegen generate --spec Apps/iOS/MobileOSHost/project.yml
xcodebuild -project Apps/iOS/MobileOSHost/MobileOSHost.xcodeproj \
  -scheme MobileOSHost -configuration Release \
  -destination 'platform=iOS Simulator,id=EA4C15A7-F725-4321-82FD-70E9F32A7645' \
  -derivedDataPath .build/graphics/PineconeDerivedData \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES PINECONE_EMBED_VIRGL=1 build
```

Dependencies and isolated Python/Meson/Ninja tools are cached under the ignored
`.build/graphics` directory. No system package installation or Linux builder is
required. The script also accepts `macosx` and `iphoneos`; only the simulator
dependency build has been exercised during this change.

Pinned Apple-compatible dependency sources:

- WebKit ANGLE: `ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10`.
- libepoxy: `bf98587477fe68d07b93319ece7b40a7d0e2eabe`.
- virglrenderer: `71a67414013f120c158729da7f56f29b55bf4f6c`.

`patch-loader-paths.py` makes framework lookup relocatable through `@rpath` and
gates the Apple fork's unused Vulkan proxy behind its explicit enable flag.
Xcode's obsolete libc++ assertion setting is disabled for this dependency
build. Original licenses and revision/patch information accompany embedded
frameworks in `GraphicsNotices`.

## Launch

Install in place without uninstalling or replacing guest disks. Set
`SIMCTL_CHILD_PINECONE_VIRGL=1` when launching with `simctl`; select Android.
The profile then uses `androidboot.graphics=mesa`, and the guest's existing
detector selects hardware Mesa from the advertised capabilities. Without this
opt-in, the software-rendering profile remains unchanged.

`PINECONE_VIRGL_LIBRARY_DIRECTORY` can explicitly select a dependency framework
directory for a macOS development process. Normal simulator launches load the
frameworks from the application's own bundle. Assembly executor selection is
independent of graphics.

### Android GPU sysfs policy

The existing image labels other virtual-machine PCI layouts but not Pinecone's
GPU at `/devices/platform/soc/30000000.pcie/pci0000:00/0000:00:05.0`.
SurfaceFlinger consequently receives SELinux denials when reading its `uevent`
file and can fall back to llvmpipe despite successful VirGL negotiation.

`scripts/graphics/prepare-android-gpu-policy.py` creates a derived disk, adds a
`sysfs_gpu` genfs label for only that PCI subtree, and removes the clone's ODM
precompiled policy so Android compiles the changed split policy. It adds no
allow or permissive rules. The current simulator probe successfully compiled
and loaded this policy with enforcing enabled. Until a matching precompiled
policy is packaged, this derived image compiles policy on every boot.

For the simulator experiment, the original system disk is preserved under
`Documents/LineageOS/VirGL-original-system/`; userdata is retained. Stop the VM
before replacing or restoring its system disk.

## Validation and current evidence

- Full Swift suite after the readback, autorelease, fence, lease and embedded-transfer fixes: 774 tests,
  two skipped, no failures. The opt-in real Metal test also passed separately.
- Device regressions cover capsets, context/resource lifetime, malformed and
  overflowing requests, backing RAM bounds, transfer directions, partial
  readback preservation, reset/ID reuse, fenced replies and display publication.
- The native smoke test executes real VirGL commands through ANGLE Metal,
  clears a BGRA texture, verifies returned pixels, uploads a four-color pattern,
  and checks reset/resource reuse. Optimized and UBSan runs passed on the Mac.
- A separate real-Metal XCTest passes through `VirtIOGPUDevice` to the existing
  display snapshot, including shader-driven triangle pixels from vertices
  uploaded from guest RAM by an embedded transfer. It uses locally installed
  UTM graphics libraries as a macOS test dependency only. Its emulator is
  neither loaded nor used.
- Native simulator tests pass BGRA/RGBA round trips with both texture
  orientations, and a separate shader-driven triangle rasterization probe.
- The simulator host initialized `ANGLE Metal Renderer: Apple iOS simulator
  GPU`; the kernel reported `+virgl` and capsets 1/2 (308/1408 bytes).
- With the precise GPU sysfs label, Android SurfaceFlinger selected `virgl`,
  OpenGL ES 3.0 Mesa 25.3.3, and the native renderer completed an actual guest
  submission (context 4, 1698 words). A host sample also captured Metal pipeline
  compilation.
- With embedded-transfer synchronization installed, Android's actual
  "Phone is starting..." window and progress indicator appeared in the existing
  monitor. The first visible-frame metrics recorded eight VirGL contexts,
  23 resources, 244 completed submissions and 12 scanout readbacks. This
  was followed by Quickstep's home screen. A swipe through the existing touch
  bridge changed Quickstep to All Apps, and the full app drawer rendered its
  icons and labels in the monitor. This establishes real Android launcher
  rendering and input through Metal; it does not establish a launcher speedup.
- After the frame-lease fix, the simulator advanced beyond the prior deadlock
  at user unlocking. A remaining System UI startup ANR showed high guest CPU
  pressure and zero memory pressure; its main thread was constructing startup
  dependencies and registering a content observer through Binder. Graphics
  acceleration does not remove this framework/interpreter startup cost.

Reproduce native smoke with a macOS framework directory:

```sh
sh scripts/run-virgl-metal-smoke.sh FRAMEWORK_DIRECTORY
sh scripts/run-virgl-metal-smoke.sh FRAMEWORK_DIRECTORY --ubsan
sh scripts/run-virgl-metal-smoke.sh .build/graphics/runtime/iphonesimulator \
  --simulator EA4C15A7-F725-4321-82FD-70E9F32A7645
```

`VirGLGPUDeviceTests.testRealMetalCommandsReachExistingGuestDisplaySurface`
is opt-in using `PINECONE_VIRGL_TEST_FRAMEWORKS`. When testing unmodified UTM
frameworks, invoke the built XCTest bundle with `xctest` and set
`DYLD_FRAMEWORK_PATH` to that directory; SwiftPM's test launcher replaces that
variable. The application-local frameworks built here use explicit runpaths.

Runtime counters under `graphics.virtioGPU` include `virglEnabled`,
`virglContexts`, `virglResources`, `virglSubmissions`, and `virglReadbacks`.
The performance report is milestone/interaction driven; check its modification
time before treating it as current. Renderer stderr records actual initialization
and the first successfully completed guest submission. Synthetic rendering
tests do not establish Android boot time, UI readiness, or responsiveness.
