# AOSP Go build for arm64viz

This repository includes a reproducible product overlay for building the
smallest useful Android UI on LineageOS's `virtio_arm64only` device. It is an
AOSP product built from a LineageOS 23.2 source tree: it deliberately omits the
Lineage app suite while retaining the upstream Lineage VirtIO kernel and device
integration.

The result is `arm64viz_virtio_arm64only_lean-user`, an AOSP Go product rather
than the full Lineage ROM. It is meant to reach a
boot animation and launcher quickly on arm64viz's software-emulated CPUs, not
to behave like a phone.

## Product contract

The product inherits LineageOS's supported `aosp_virtio_arm64only_go` baseline
and keeps:

- the 64-bit Android framework, Binder, servicemanager, APEX, Zygote, and
  `system_server`;
- SurfaceFlinger, DRM HWComposer, minigbm, and the Mesa software renderer;
- SystemUI, Settings, and `Launcher3QuickStepGo`, each speed-preoptimized;
- AOSP's `Provision` app to finish first-boot provisioning without SetupWizard;
- VirtIO PCI block, GPU, input, and Ethernet support;
- dynamic partitions, first-stage init, the vendor ramdisk, userdata, and the
  UTM disk-image packaging used by the existing arm64viz guest.

It selects a `user` build, the Android Go low-memory configuration, and no
setup wizard. It excludes the Lineage application bundle and optional camera,
telephony, AudioFX, virtual Wi-Fi, Bluetooth HAL, sensor HAL, external-camera
HAL, audio-device setup, and engineering/debug payloads. Core framework APIs
may still contain stubs for unsupported hardware; the corresponding device
HAL processes and feature declarations are what this product removes.

The output gate requires `ro.config.low_ram=true`, the Go launcher and
provisioner, and rejects SetupWizard/Google-services payloads. The product has
not yet been built or boot-verified; passing synthetic output-gate tests is not
evidence of a bootable ROM. The previously installed Lineage image remains the
known working reference. No matching Go prebuilt was found among the current
image publisher's release assets.

Do not remove health, power, KeyMint/Gatekeeper, graphics allocator/composer,
or APEX packages merely because arm64viz does not emulate matching physical
hardware. Android's boot-completion path expects those default virtual-device
implementations.

## Host requirements

Build on a current 64-bit Linux host. A full Android source build is not
practical on macOS and typically needs roughly 64 GiB RAM and 400 GiB free
disk. Install LineageOS's standard build dependencies, Git LFS, the `repo`
tool, `qemu-img`, `unzip`, and a Java version supported by LineageOS 23.2.

The overlay is intentionally separate from the Android checkout. The checkout
is large and remains outside this repository.

## Linux CI builder

The checked-in GitHub Actions workflow
`.github/workflows/build-lineageos-lean.yml` runs only when manually
dispatched. It deliberately targets a trusted self-hosted runner with all four
labels `self-hosted`, `linux`, `x64`, and `lineageos-builder`; an ordinary
GitHub-hosted runner does not have enough disk for this build. Provision that
runner with at least 64 GiB RAM, 400 GiB free SSD, and a persistent
`/srv/lineageos` volume. Do not attach the same runner label to workflows that
execute unreviewed pull-request code.

On Ubuntu 24.04, a representative one-time host setup is:

```sh
sudo apt-get update
sudo apt-get install -y \
  bison build-essential ccache curl flex fontconfig git-core git-lfs gnupg \
  lib32z1-dev libc6-dev-i386 libgl1-mesa-dev libx11-dev libxml2-utils \
  qemu-utils repo unzip x11proto-core-dev xsltproc zip zlib1g-dev zstd
sudo install -d -o "$(id -u)" -g "$(id -g)" /srv/lineageos
git lfs install
```

Register the runner with the repository or organization, add the custom
`lineageos-builder` label, and keep the runner service account unprivileged
after provisioning. The Android build uses source-tree prebuilts for its Java
and compiler toolchains; `ci-build.sh` performs a host-tool and free-space
preflight before downloading source.

After this workflow file is committed and pushed, the exact manual launch is:

```sh
gh workflow run build-lineageos-lean.yml \
  --ref YOUR_BRANCH \
  -f source_root=/srv/lineageos/lineage-23.2 \
  -f sync_source=true \
  -f sync_jobs=8 \
  -f build_jobs=16 \
  -f minimum_free_gib=350 \
  -f upload_artifact=true \
  -f artifact_retention_days=3
```

The first build initializes and syncs the checkout. Later builds reuse the
checkout and its `out/` directory but still run `installclean` before selecting
the arm64viz product. Set `sync_source=false` only to reproduce commits already
pinned in that checkout. The workflow uses `--force-sync`, so `source_root`
must be a dedicated Android checkout with no hand-maintained project changes.

The equivalent command when logged into the Linux builder is:

```sh
LINEAGEOS_SYNC=1 \
LINEAGEOS_SYNC_JOBS=8 \
ARM64VIZ_BUILD_JOBS=16 \
ARM64VIZ_MIN_FREE_GIB=350 \
  scripts/lineageos-lean/ci-build.sh \
    /srv/lineageos/lineage-23.2 \
    /srv/lineageos/arm64viz-lean-output

scripts/lineageos-lean/package-ci-artifacts.sh \
  /srv/lineageos/arm64viz-lean-output \
  /srv/lineageos/arm64viz-lean-upload
```

### CI artifact policy

The workflow does not put the Android source checkout, `out/`, or ccache into
GitHub's cache or artifact service. The staged raw disks are GNU sparse-tarred,
compressed once with zstd, and split into 1,800 MiB pieces; upload-artifact's
second compression pass is disabled. The UTM zip is excluded because it
duplicates the same two disks. Default retention is three days and can be
reduced to one day. Exact source revisions, overlay checksums, image checksums,
and build metadata remain in the bundle.

Download the workflow artifact and reconstruct it on Linux with:

```sh
sha256sum -c PART-SHA256SUMS
cat arm64viz-lineageos-lean.tar.zst.part-* > arm64viz-lineageos-lean.tar.zst
zstd -dc arm64viz-lineageos-lean.tar.zst | tar -xf -
```

On macOS, install `gnu-tar` and `zstd` with Homebrew and replace the last
command's `tar` with `gtar`. Extraction needs enough *logical* space for both
raw disks even though their zero extents remain sparse.

The automation has been syntax- and packaging-tested without starting the
remote workflow or an Android build. The remaining external blockers are a
properly labeled large Linux runner, the initial LineageOS source download,
and possible upstream `lineage-23.2` device-makefile drift that would require
refreshing the two small checked-in patches.

## Sync LineageOS 23.2

```sh
mkdir -p "$HOME/android/lineage-23.2"
cd "$HOME/android/lineage-23.2"
repo init \
  -u https://github.com/LineageOS/android.git \
  -b lineage-23.2 \
  --git-lfs --no-clone-bundle
repo sync -c --prune --force-sync --fail-fast --retry-fetches=8 -j8
```

The branch name selects a moving maintenance branch. Every successful build
therefore writes `pinned-manifest.xml` containing the exact project commits and
`SHA256SUMS` for the staged artifacts. Preserve those two files with any build
you intend to reproduce or distribute.

## Build and stage Pinecone inputs

From the arm64viz checkout:

```sh
ARM64VIZ_BUILD_JOBS=8 \
  scripts/lineageos-lean/build.sh \
  "$HOME/android/lineage-23.2" \
  artifacts/lineageos-lean-local
```

The build driver performs four operations:

1. installs the product definition under
   `device/arm64viz/virtio_arm64only_lean`;
2. applies small, idempotent patches to `device/virt/virt-common` and
   `device/mainline/common` so Wi-Fi, audio, Bluetooth, and sensor payloads can
   be disabled by a child product;
3. lunches `arm64viz_virtio_arm64only_lean-user`, runs `installclean` to avoid
   inheriting files from the upstream product's shared output directory, and
   builds `vm-utm-zip`;
4. verifies the user/UI/APEX contract, extracts the UTM archive, and converts
   its QCOW2 disks to sparse raw images.

The output directory contains:

- `boot.img` and `vendor_boot.img` (plus `init_boot.img` when generated);
- `vda.raw`, the partitioned Android system disk;
- `vdb.raw`, writable userdata;
- the original `UTM-VM-*.zip`;
- `pinned-manifest.xml`, the exact overlay archive and overlay checksums,
  `build-metadata.txt`, and `SHA256SUMS`.

The staging step refuses to overwrite an existing output directory. Pick a new
directory for every build so image/provenance files cannot be mixed.

To install or inspect the product without starting a multi-hour build:

```sh
scripts/lineageos-lean/install-overlay.sh "$HOME/android/lineage-23.2"
```

To build extra standard Android targets, override `ARM64VIZ_M_TARGETS`:

```sh
ARM64VIZ_M_TARGETS="vm-utm-zip otapackage" \
  scripts/lineageos-lean/build.sh "$HOME/android/lineage-23.2" /tmp/arm64viz-lean
```

## Boot with arm64viz

```sh
swift run -c release arm64viz run-lineageos-trace \
  artifacts/lineageos-lean-local/boot.img \
  --vendor-boot artifacts/lineageos-lean-local/vendor_boot.img \
  --disk artifacts/lineageos-lean-local/vda.raw \
  --secondary-disk artifacts/lineageos-lean-local/vdb.raw \
  --memory-mib 1024 --vcpus 4 --max-steps 50000000000 \
  --stop-on-display --uart-no-progress-timeout-ms 300000 \
  --display-snapshot /tmp/arm64viz-lineageos-final.ppm \
  > /tmp/arm64viz-lineageos-trace.json
```

If the build emits `init_boot.img`, also pass
`--init-boot artifacts/lineageos-lean-local/init_boot.img`.

For the iOS app, copy the same boot, vendor-boot, system-disk, userdata-disk,
and optional init-boot files into the app's LineageOS document directory. The
lean build has virtual Wi-Fi disabled at product-build time, so it does not
need `patch-lineageos-vendor-dlkm.sh` or the `vda-arm64viz.raw` workaround used
by the downloaded general-purpose image.

## Expected first UI

The first guest-owned pixels should be Android's boot animation, followed by
SystemUI and Launcher3. The product does not include Lineage SetupWizard, so a
fresh userdata image should not stop at account or phone provisioning.

If verification fails because an upstream Lineage module was renamed, update
the explicit package name in the product and `verify-output.sh` together. Do
not weaken the verifier: silently producing an image without a launcher would
defeat the purpose of this build profile.
