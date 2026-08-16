# Pinecone Paravirtual Graphics

Pinecone keeps the standard VirtIO-GPU 2D interface for unmodified Linux
guests. An open-source guest may additionally send Pinecone's versioned 2D
payload through `VIRTIO_GPU_CMD_SUBMIT_3D`. No QEMU or JIT is involved.

## Data Path

1. A checksum-pinned Pixman build invokes Pinecone's weak compositor hook after
   Pixman computes exact clipping. `libpinecone-pixman.so` tracks image state
   and DRM dumb-buffer mappings in the guest.
2. Eligible Pixman-owned ARGB/XRGB/A8 images are allocated directly from mapped
   DRM dumb buffers. Their GEM handle remains stable for the image lifetime and
   the backing is released only when the final `pixman_image_unref` destroys
   the image. Packed A8 masks retain their native byte layout in shared GEM
   memory instead of expanding through a scratch upload. The bridge submits
   exact Pixman `CLEAR`, `SRC`, `DST`, `OVER`, and `ADD` operators,
   including positive axis-aligned crop/scale transforms with nearest or
   bilinear sampling. DRM-backed sources are referenced directly. Other Cairo
   sources use one reusable, growable upload surface. Solid-color operations
   carry no source resource. Solid-alpha, A8/ARGB, and component-alpha masks use
   explicit protocol v5 flags.
3. Pixman composites collect up to 64 clipped operations into a frame-wide
   version 4 command list containing v5 records. Stable DRM-backed source, mask,
   and destination surfaces remain referenced by GEM slot until the next DRM
   presentation ioctl. Reusable uploads, unsupported CPU composites,
   `pixman_image_get_data`, image destruction, and unmapping are ordered hazards
   that flush the list before bytes or handles can be reused.
4. A non-DRM destination can use a coherent scratch surface when that process
   already owns a DRM mapping. The bridge copies only the affected rectangle
   into shared backing, executes synchronously, and copies it back. It does not
   open a DRM device solely to submit a scratch operation.
5. The patched VirtIO-GPU driver validates 64-byte v3 and v5 payloads or the
   bounded v4 envelope, validates every nested record and GEM slot, and
   translates userspace slots into host resource IDs.
6. ARM64VizCore validates every resource, rectangle, format, and backing range.
   A batch is accepted by an accelerator as a whole or replayed in order by the
   native C raster backend.
7. Pinecone executes exact clear/source/destination/source-over/add blending,
   solid sources, scaling, scalar masks, packed A8 masks, component-alpha masks,
   and XRGB/premultiplied-alpha conversion
   with one Metal compute encoder and command buffer per batch. The aggregate
   pixel count selects Metal, allowing glyph and icon rectangles that were too
   small individually to use it. On physical devices, contiguous guest backing
   is wrapped as page-aligned shared Metal storage. The simulator uploads inputs
   only before their first GPU read, keeps write-after-read/write ordering in
   the command buffer, unions destination damage by resource, and copies each
   union back once.
8. Every batch requests one VirtIO-GPU output fence. Pixman waits at the DRM
   presentation boundary, or earlier at an upload/CPU hazard, rather than once
   per public composite call. Direct shared destinations avoid copy-back on a
   physical device without exposing partially completed Metal writes.
9. The VirtIO queue drains all available descriptors and publishes one used-ring
   interrupt. A v4 list therefore pays one descriptor traversal, response, and
   interrupt for as many as 64 graphics operations.
10. Core falls back to its native C raster backend if Metal is unavailable. This
   is a host graphics fallback, not the ARM64 instruction fallback interpreter.

Disjoint/conjoint and artistic blend operators, transformed masks, rotations,
reflections, perspective transforms, complex filters, alpha maps, unsupported
formats, destinations without an existing process-local DRM device, or invalid
geometry remain in upstream Pixman. Power-of-two telemetry reports exact
operator hit/total counts plus mask and geometry histograms.

Pixman/Cairo-owned compositor and application surfaces use the registered DRM
allocator and retain stable GEM handles. The bridge exports these allocations
as linear dma-bufs through `pinecone_pixman_export_dmabuf`; the installed
`pinecone/pinecone-pixman.h` defines the ownership contract for a Wayland
linux-dmabuf allocator. Caller-owned image data, including existing wl_shm
pools, cannot be replaced after allocation because the caller owns the pointer
contract; those sources still use a reusable upload surface and are not counted
as zero-copy.

Framebuffer commits retain exact dirty rectangles. The iOS presenter uploads
only those rectangles on the simulator, wraps stable page-aligned framebuffer
memory on physical devices, coalesces generations, and presents only pending
damage at a `CADisplayLink` refresh boundary.

## Wire Payload

Version 3 is the legacy little-endian 64-byte payload starting with magic
`PN2D`. Version 5 keeps that record size, carries the exact stable Pixman
operator value, and adds solid-source, component-alpha, and packed-A8 flags.
Version 4 is a 16-byte envelope followed by 1 to 64 complete v3 or v5 records.
The envelope declares its record count, fixed record size, total byte count,
and zero reserved flags. Source records carry explicit extents for scaling.
The final words carry either a mask resource ID or an 8-bit scalar mask alpha;
inconsistent flag/resource combinations are rejected.
Resource IDs are rewritten by the guest kernel and are never trusted from
userspace. V4 userspace records contain 1-based slots into one deduplicated GEM
handle table; the guest kernel validates and rewrites every slot before submit.
