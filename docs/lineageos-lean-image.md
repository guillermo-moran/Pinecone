# LineageOS image inspection and trimming

The pinned `virtio_arm64only` disk can be inspected and patched without
changing the downloaded artifact. The repository workflow has two deliberate
limits:

1. inspection is read-only and validates GPT plus Android `liblp` checksums;
2. post-build mutation is restricted to a checksum-pinned manifest and writes
   to a new APFS copy-on-write clone.

This distinction matters. Removing files from an ext4 logical partition does
not shrink its fixed `liblp` extent, and deleting arbitrary Android packages or
init files after a build can violate AVB, SELinux, VINTF, priv-app permission,
or package-overlay assumptions. A genuinely smaller and faster image should be
built from a lean product definition. Post-build patching is reserved for the
small workaround that is already proven during Pinecone bring-up.

## Reproducible inspection

Inspect the raw disk and list every GPT and dynamic partition:

```sh
scripts/inspect-lineageos-image.py \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/vda.raw
```

Use `--json` for automation. Logical partitions may be extracted for read-only
analysis without `lpunpack`:

```sh
out=$(mktemp -d /tmp/arm64viz-lineage-inspect.XXXXXX)
scripts/inspect-lineageos-image.py \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/vda.raw \
  --extract product --extract system_ext --extract vendor \
  --output-dir "$out"
```

Extraction uses exclusive file creation and refuses to overwrite an existing
partition image. `debugfs -R 'ls -p /app' "$out/product.img"` is useful for
read-only filesystem inventory.

The pinned disk currently contains seven single-extent logical partitions:

| Partition | Bytes | Relevant contents |
| --- | ---: | --- |
| `system_dlkm` | 307,200 | system kernel modules |
| `vendor_dlkm` | 15,831,040 | `btusb`, `cfg80211`, `virt_wifi` boot list |
| `product` | 1,544,613,888 | optional Lineage apps and product configuration |
| `system` | 1,081,044,992 | Android framework, APEX, native core services |
| `system_ext` | 564,109,312 | launcher, SystemUI, Settings and Lineage services |
| `odm` | 135,102,464 | device configuration |
| `vendor` | 386,785,280 | VirtIO graphics, security HALs, init services |

## Safe post-build plan

The default command is a dry run:

```sh
scripts/apply-lineageos-image-plan.py \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/vda.raw
```

It checks all of the following before accepting the plan:

- the complete 5 GiB source SHA-256 and size;
- GPT header and partition-table CRC32 values;
- `liblp` geometry, header, and table SHA-256 values;
- the old and replacement file SHA-256 values;
- the target logical partition, extent type, and filesystem path.

Apply the checked plan only to a new output:

```sh
scripts/apply-lineageos-image-plan.py \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/vda.raw \
  --apply \
  --output artifacts/lineageos-virtio-arm64only-v2026.10.18/vda-lean.raw
```

Application requires e2fsprogs `debugfs` and `e2fsck`. Their paths may be set
with `LINEAGE_DEBUGFS` and `LINEAGE_E2FSCK`. The output must be on a filesystem
whose `cp` supports `-c`; the tool intentionally fails instead of silently
making a fully allocated 5 GiB copy. It runs `e2fsck`, writes only the verified
single linear extent, and emits a neighboring `.provenance.json` record. It
never opens the source disk for writing.

The checked-in [image plan](../scripts/lineageos-image-plan.json) performs two
emulator workarounds: it replaces `vendor_dlkm`'s crashing `virt_wifi` module
with the `bluetooth` dependency needed by `btusb`, and it uses an unencrypted
userdata mount because the stub KeyMint service cannot persist Android's
file-encryption keys across emulator boots. The latter is suitable only for
local emulator bring-up. Both changes retain source, file, metadata, clone,
and provenance guards.

## What a lean source build should remove

The following are good first-stage build-time removals because none provides
the launcher, SystemUI, Settings, SurfaceFlinger, or the VirtIO display path.
Remove each item through the product/device makefiles so its APK, init file,
VINTF fragment, permission declaration, and dependencies stay consistent.

### Low-risk applications

The pinned `product` partition contains these optional user applications:

- `Aperture` and `ApertureLensLauncher` (camera);
- `Backgrounds` and `PhotoTable`;
- `DeskClock`, `Etar`, and `ExactCalculator`;
- `Gallery2` and `Glimpse`;
- `Jelly` (browser);
- `Recorder`;
- `Twelve` (music).

`Camelot` and `ThemesStub` should be checked against the selected Lineage
product before removal because they may supply compatibility or theme stubs.
`ModuleMetadata` and `webview` are framework-facing and should remain.
`LatinIME` is useful for an interactive emulator and should remain initially.

`Seedvault` and `Updater` in `system_ext/priv-app` are optional for a local VM,
but remove their init, permission, and configuration entries together with the
packages. Keep `LineageSetupWizard` until a clean first boot is known to reach
the launcher, or explicitly configure the product to provision setup state.

### Hardware features

- **Bluetooth:** remove `android.hardware.bluetooth-service.default`, its
  vendor init/VINTF fragments, Bluetooth framework packages, and `btusb` plus
  `bluetooth` modules as one source-build feature. Removing only the service
  leaves a declared HAL that framework code can wait for.
- **Wi-Fi:** remove the `virt_wifi`/`cfg80211` modules, `virt_wifi.rc`,
  `setup_wifi.rc`, Wi-Fi HAL/framework packages, feature XML, and product
  properties together. VirtIO Ethernet remains the intended network device.
- **Camera:** remove the camera application and camera provider/features. The
  pinned vendor partition does not expose a camera HAL.
- **Audio:** audio is not needed to compose a launcher, but deleting only
  `audio.primary.default.so` makes AudioFlinger repeatedly search for a HAL.
  Disable audio coherently in the product or keep the small default stub until
  the UI milestone is reached.
- **OpenSSH:** `product/etc/init/init.openssh.rc` is development-only and can be
  removed from a non-debug product.

Keep the vendor gralloc/mapper and VirtIO Vulkan implementation until
SurfaceFlinger is proven. Also keep KeyMint/security services, which are used by
keystore and credential flows, and keep `init.logcat-to-serial.rc` during
bring-up because it provides the evidence needed to diagnose framework stalls.
Zram should remain with a 1 GiB guest until peak Android memory use is measured.

## UI-critical preserve set

At minimum, preserve these pinned-image components:

- `system/bin/surfaceflinger` and the Android framework/APEX set;
- `system_ext/priv-app/Launcher3QuickStep`;
- `system_ext/priv-app/SystemUI`;
- `system_ext/priv-app/Settings`;
- `product/priv-app/SettingsIntelligence`;
- `system_ext/priv-app/LineageSettingsProvider` and, initially,
  `LineageParts`;
- `vendor/lib64/hw/gralloc.default.so`;
- `vendor/lib64/hw/mapper.minigbm_upstream.so`;
- `vendor/lib64/hw/vulkan.virtio.so` and its dependencies;
- input method support such as `product/app/LatinIME`.

Do not edit APEX payloads after the build. They are signed, dependency-coupled,
and activated before Zygote. Do not delete preinstalled APK directories merely
to reduce the raw image: their fixed partition extents remain the same size.
Rebuild the product and super images so Android's package lists, SELinux policy,
VINTF data, filesystem sizing, and AVB metadata are generated together.

For emulator bring-up, the pinned image can also avoid guest-side CAPEX
decompression without changing any signed APEX payload. The preparation tool
extracts each signed `original_apex` from its CAPEX wrapper and places it in a
new copy-on-write disk. It removes only the unused Android Virtualization
Framework APEX to provide the extra system-partition space:

```sh
scripts/prepare-lineageos-preexpanded-apex.py \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/vda-arm64viz.raw \
  artifacts/lineageos-virtio-arm64only-v2026.10.18/vda-preexpanded.raw
```

The source remains untouched, all retained APEX signatures and payloads are
byte-for-byte identical, and a provenance record is written beside the output.
This is a boot-speed workaround; the source product definition remains the
right place for permanent package removal.

## Acceptance order

Apply removals incrementally and retain one known-good image per phase:

1. boot the unmodified source plus the `virt_wifi` workaround;
2. remove only optional applications and OpenSSH in the source build;
3. prove boot animation, SurfaceFlinger, SystemUI, and launcher;
4. remove Bluetooth and Wi-Fi as coordinated product features;
5. consider audio, setup wizard, logging, zram, or alternate Vulkan drivers
   only after boot timing and framework logs show they are safe.

For each phase, record the source revision, product makefile diff, image
checksums, boot time to Zygote/SurfaceFlinger/launcher, and the first fatal init
or VINTF error. File deletion without those measurements is image-size churn,
not a demonstrated boot optimization.
