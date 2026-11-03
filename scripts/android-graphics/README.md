# Android layer bridge preparation

This directory contains a portable command encoder, a DRM submission library,
and host compatibility tests,
not an installed Android Hardware Composer HAL. Android currently continues
to render through Mesa/llvmpipe. No Android driver, image or device policy is
changed by these files.

`pinecone_layer_encoder.h` encodes a conservative subset of composer layers
into the **existing v3 Alpine/Pixman graphics protocol**: premultiplied BGRA or
opaque BGRX, integral in-bounds crop, scaling, source-over and scalar plane
alpha. It explicitly rejects transforms, protected buffers, unsupported
formats, invalid rectangles and aliased source/destination resources. Rejection
leaves the payload untouched. It has no Android, Pixman or libc allocation
dependency and writes explicit little-endian fields.

`AndroidLayerEncoderTests` compiles the actual C encoder, runs its rejection
checks, submits its output to `VirtIOGPUDevice`, and verifies resulting guest
pixels for a scaled source with plane alpha. This proves protocol and CPU
composition compatibility; it does not benchmark or execute Metal. Host Metal
dispatch uses the same decoded commands but needs simulator/device validation.

## Guest DRM transport

`pinecone_drm_transport.c` implements submission of one supported layer through
the patched virtio DRM execbuffer ioctl. Layer resource fields are imported
GEM handles belonging to the supplied DRM file. The library waits for both
borrowed acquire fences against one bounded monotonic deadline, submits the
source/destination handles in the order required by the kernel patch, and
returns an owned composition-completion sync-file descriptor. Failure leaves
the output descriptor at -1. An interrupted ioctl is not retried because the
submission's acceptance could be ambiguous. No caller buffer or acquire fence
is closed by the library. Retain both buffers until completion; the returned
fence is not a display-present fence.
The timeout bounds acquire-fence waits, not the ioctl's execution time. If
submission fails after entering the driver, do not immediately reuse or render
over the target: acceptance may be ambiguous and a completion fence may be
unavailable. Retain the buffer leases until queue teardown or another driver
completion guarantee. Only validation/acquire-stage failures are known to have
submitted no work.

The syscall-injection fixture checks synchronization and submission failures
without pretending to exercise a real DRM driver. The normal entry point uses
Linux poll/clock/ioctl; non-Linux builds reject real submission. Android's
composer must still own gralloc imports, GEM-handle reference accounting,
display-wide validation, clearing, z-order and KMS presentation.

`scripts/lineageos-lean/install-overlay.sh ANDROID_SOURCE_ROOT` now stages this
library under `device/arm64viz/pinecone_graphics`. After sourcing Android's
build environment and selecting the lean product, build it explicitly with:

```sh
m libpinecone_android_graphics_transport
```

This is an Android vendor static library, not a composer service or installed
HAL. Its Android build has not yet been run in a synced Lineage tree. Staging
it does not enable acceleration or apply the kernel patch.

## Required Android integration

1. Port `scripts/patches/linux-virtio-gpu-pinecone-2d.patch` to the Lineage
   kernel's virtio DRM driver. Alpine relies on that patch to recognize the
   private execbuffer payload, validate handles and relocate process-local GEM
   handles to actual virtio resource IDs. Stock execbuffer support alone is
   insufficient. Preserve ordered completion and output fence behavior.
2. Build an Android composer backend against the **exact** composer interface
   in the selected Lineage tree. Import gralloc DMA-BUF descriptors into one DRM
   file namespace, retain allocations until all relevant fences complete, and
   resolve per-plane pitches, offsets and modifiers. Never treat a DMA-BUF fd,
   native_handle pointer, or GEM handle as a host resource ID.
3. During validation accept only supported SDR/sRGB layers, identity transform,
   integral crop, linear single-plane BGRA/BGRX with known alpha semantics and
   no protected content. Reject coverage blending, color transforms, HDR,
   YUV/RGBA and unsupported modifiers to CLIENT composition. The portable
   encoder cannot itself validate Android dataspace or native-handle metadata;
   the backend must do so before calling it. Mixed DEVICE/CLIENT ordering
   requires explicit client-target handling; initially fall back the entire
   display when any layer is unsupported.
4. During presentation wait or import **all acquire fences**, clear the target,
   and compose accepted layers in z order. Submit the payload with its source
   and destination BO handles using the patched execbuffer path. Return a
   release fence representing each producer buffer's last read and a present
   fence representing actual display completion. Command submission is not
   presentation. Keep software fallback and synchronization intact on error.
5. Integrate Android.bp/product packaging, service manifest/init and narrowly
   scoped device policy. Use `docs/lean-lineageos-build.md`'s Linux build path;
   the Android source tree and rebuilt kernel/HAL are not present here.
6. Verify alpha, scaled crops, damage, triple buffering, producer reuse, fence
   errors, reset, rotations/fallback and real Android UI screenshots. Compare
   host accelerator counters and end-to-end frame latency before enabling.

This accelerates final composition. Skia/HWUI app drawing and LLVM shader
compilation remain separate work and may still dominate startup. A graphics
driver/RenderEngine path or a Skia adapter is required to accelerate those.
Touch continues through UIKit -> Pinecone VirtIO input -> Android InputReader;
the graphics bridge and Metal do not replace Android's input dispatch.
