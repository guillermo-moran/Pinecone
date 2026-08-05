# Pinecone

Pinecone is an internal iOS hardware test harness for arm64viz. The JavaScript
MobileOS runtime is disabled. The app now boots the open Linux shell canary
through ARM64VizCore and streams the guest PL011 console as a full-screen
`ttyAMA0` terminal.

It does not replace iOS, alter the device boot chain, use private entitlements,
or escape the application sandbox.

## What It Tests

- ARM64VizCore running on iPhone hardware.
- `LinuxDirectBootAdapter` loading an ARM64 Linux `Image`.
- Generated binary FDT address and size.
- Minimal console initramfs with BusyBox `/bin/sh` on `ttyAMA0`.
- Bundled ext4 `rootfs.ext4` attached through virtio-mmio block for the
  persistent-root track.
- Live PL011 output and receive injection from the SwiftUI terminal.

## Runtime Boundary

Swift is the native iOS container, VM bridge, and host shell surface. The guest
runtime is the bundled open Linux shell image:

- `artifacts/linux-shell/out/Image`
- `artifacts/linux-shell/out/initramfs-minimal-ttyinit.cpio`
- `artifacts/linux-shell/out/rootfs.ext4`

The app uses the same boot arguments as the desktop shell canary:

```text
console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/bin/sh loglevel=7
```

The app seeds a writable `rootfs.ext4` copy under Application Support and boots
the persistent-root path:

```text
console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 root=/dev/vda rw rootwait rdinit=/init loglevel=7 ignore_loglevel printk.time=1 print-fatal-signals=1 initcall_debug
```

The terminal view prints guest UART output only. Host status, step count, and
errors stay outside the console stream.

## Build

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
