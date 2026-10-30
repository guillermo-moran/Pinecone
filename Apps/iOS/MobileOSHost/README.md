# Pinecone

Pinecone is an internal iOS hardware test harness for arm64viz.
The app boots ARM64 Alpine Linux and Phosh through
ARM64VizCore, with a full-screen guest display and a PL011 `ttyAMA0` terminal.

It does not replace iOS, alter the device boot chain, use private entitlements,
or escape the application sandbox.

## What It Tests

- ARM64VizCore running on iPhone hardware.
- `LinuxDirectBootAdapter` loading an ARM64 Linux `Image`.
- Generated binary FDT address and size.
- Minimal initramfs handing off to the persistent Alpine root and its shell.
- Bundled ext4 `rootfs.ext4` attached through virtio-mmio block for the
  persistent-root track.
- Live PL011 output and receive injection from the SwiftUI terminal.

## Runtime Boundary

Swift is the native iOS container, VM bridge, and host shell surface. The guest
runtime is the bundled open Linux shell image:

- `artifacts/linux-shell/out/Image`
- `artifacts/linux-shell/out/initramfs-minimal-ttyinit.cpio`
- `artifacts/linux-shell/out/rootfs.ext4`

The app seeds a writable `rootfs.ext4` copy under Application Support and boots
the persistent-root path:

```text
console=ttyAMA0 root=/dev/vda rw rootwait rdinit=/init loglevel=4 printk.time=1
```

It also passes the current Unix time to the guest. Set `PINECONE_VERBOSE_BOOT=1`
for the early console and detailed kernel messages. Phosh auto-launches after
the shell is ready and the app switches to Display on the readiness marker.

The terminal view prints guest UART output only. Host status, step count, and
errors stay outside the console stream.

## Build

### Current Physical-Device Test Configuration

- Assembly-backed native execution is enabled by default on iOS, including
  launches from the Home Screen without Xcode environment variables. Instructions
  outside the assembly subset continue through the native C executor, not Swift
  fallback.
- Two parallel vCPUs; 384 MiB guest RAM on physical devices and 1024 MiB in the
  Simulator. Host memory use is higher than guest RAM alone.
- Assembly service/bounded chaining and the older threaded experiments remain
  off by default. Profiling is also off by default.
- The bundled rootfs uses musl `1.2.6-r10` and removes Phosh's decorative launch
  icon shadows. This is a user-requested test promotion, not a claim that touch
  latency or rendering correctness is solved. Settings can intermittently lack
  its title bar, including on the previous runtime.

Use the **MobileOSHost** scheme in **Release**, select your development team and
iPhone, then Run. The app's identifier remains `me.gmoran.pinecone`. No special
launch environment is required. Set `PINECONE_ASSEMBLY_EXECUTOR=0` in the scheme
only when comparing against the established C executor; remove stale prototype
or chaining environment overrides when testing the current defaults.

An updated bundled rootfs seeds a new writable guest disk on first launch. The
previous writable disk is retained as `rootfs.previous.ext4`; this is not an
in-place package upgrade and only one previous disk is retained. Do not uninstall
the app if you need its existing guest files. Allow storage for the bundled,
current, and previous images.

The generated image and `rootfs.ext4.sha256` must both be included in Resources.
Changing the checksum causes existing installations to recognize the new image.
To rebuild the guest from the current source/package overlays:

```sh
bash scripts/build-pinecone-musl.sh
PINECONE_CACHE_LIMA_INSTANCE=pinecone-builder \
  PINECONE_REUSE_PIXMAN_LIBRARY=1 PINECONE_REUSE_CAIRO_LIBRARY=1 \
  bash scripts/build-arm64-rootfs-image.sh
```

Run these from the repository root. The reuse flags require the existing verified
Pixman/Cairo artifacts; omit them when rebuilding those libraries too. The r8
comparison image can still be built with `PINECONE_MUSL_PACKAGE_VERSION=1.2.6-r8`.

### Xcode

Regenerate the project after changing `project.yml`:

```sh
xcodegen generate --spec project.yml
```

Build without signing for source validation:

```sh
xcodebuild -project MobileOSHost.xcodeproj -scheme MobileOSHost -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO -derivedDataPath .DerivedData build
```

To install on a real iPhone, open `MobileOSHost.xcodeproj` in Xcode, select
your development team, select a connected device, and run the app with normal
Apple developer signing.
