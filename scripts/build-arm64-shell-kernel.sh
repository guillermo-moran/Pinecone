#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${LINUX_VERSION:-6.18.38}"
KERNEL_SERIES="${KERNEL_SERIES:-v6.x}"
URL="${LINUX_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/${KERNEL_SERIES}/linux-${VERSION}.tar.xz}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/artifacts/linux-shell}"
SRC_DIR="${WORK_DIR}/linux-${VERSION}"
BUILD_DIR="${WORK_DIR}/build"
OUT_DIR="${WORK_DIR}/out"
TARBALL="${WORK_DIR}/linux-${VERSION}.tar.xz"
HOST_INCLUDE_DIR="${WORK_DIR}/host-include"

LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}"
LLD_BIN="${LLD_BIN:-/opt/homebrew/opt/lld/bin}"
MAKE_BIN="${MAKE_BIN:-/opt/homebrew/opt/make/libexec/gnubin}"
PATH="${MAKE_BIN}:${LLVM_BIN}:${LLD_BIN}:${PATH}"

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
HOST_CC="${HOSTCC:-/usr/bin/clang}"
HOST_CXX="${HOSTCXX:-/usr/bin/clang++}"
HOST_FLAGS=()
HOST_LD_FLAGS=()
if [[ -n "${SDKROOT}" ]]; then
  HOST_FLAGS=(-isysroot "${SDKROOT}")
  HOST_LD_FLAGS=(-isysroot "${SDKROOT}")
fi
if [[ -d /opt/homebrew/opt/libelf/include ]]; then
  HOST_FLAGS+=(-I/opt/homebrew/opt/libelf/include)
  HOST_LD_FLAGS+=(-L/opt/homebrew/opt/libelf/lib)
fi

mkdir -p "${WORK_DIR}" "${OUT_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  curl --fail --location --output "${TARBALL}" "${URL}"
fi

if [[ ! -d "${SRC_DIR}" ]]; then
  tar -C "${WORK_DIR}" -xf "${TARBALL}"
fi

PINECONE_GPU_PATCH="${ROOT_DIR}/scripts/patches/linux-virtio-gpu-pinecone-2d.patch"
PINECONE_GPU_PATCH_STAMP="${SRC_DIR}/.pinecone-gpu-patch.sha256"
PINECONE_GPU_PATCH_SHA256="$(shasum -a 256 "${PINECONE_GPU_PATCH}" | awk '{print $1}')"
APPLIED_PINECONE_GPU_PATCH_SHA256="$(cat "${PINECONE_GPU_PATCH_STAMP}" 2>/dev/null || true)"
if [[ "${APPLIED_PINECONE_GPU_PATCH_SHA256}" != "${PINECONE_GPU_PATCH_SHA256}" ]]; then
  tar -xOf "${TARBALL}" \
    "linux-${VERSION}/drivers/gpu/drm/virtio/virtgpu_submit.c" \
    > "${SRC_DIR}/drivers/gpu/drm/virtio/virtgpu_submit.c"
  patch -d "${SRC_DIR}" -p1 < "${PINECONE_GPU_PATCH}"
  printf '%s\n' "${PINECONE_GPU_PATCH_SHA256}" > "${PINECONE_GPU_PATCH_STAMP}"
fi

perl -0pi -e 's#sed -i '\''s/\\x00\\\+\$\$/\\x00/g'\'' \$@;#perl -0pi -e '\''s/\\x00+\\z/\\x00/'\'' \$@;#' \
  "${SRC_DIR}/scripts/Makefile.vmlinux"

mkdir -p "${HOST_INCLUDE_DIR}"
cat > "${HOST_INCLUDE_DIR}/elf.h" <<EOF
#ifndef ARM64VIZ_COMPAT_ELF_H
#define ARM64VIZ_COMPAT_ELF_H
#if __has_include(<libelf/libelf.h>)
#include <libelf/libelf.h>
#else
#include <linux/elf.h>
#endif
#ifndef SHN_XINDEX
#define SHN_XINDEX 0xffff
#endif
#ifndef SHT_SYMTAB_SHNDX
#define SHT_SYMTAB_SHNDX 18
#endif
#ifndef STT_SPARC_REGISTER
#define STT_SPARC_REGISTER 13
#endif
#ifndef R_386_32
#define R_386_32 1
#endif
#ifndef R_386_PC32
#define R_386_PC32 2
#endif
#ifndef R_ARM_PC24
#define R_ARM_PC24 1
#endif
#ifndef R_ARM_ABS32
#define R_ARM_ABS32 2
#endif
#ifndef R_ARM_REL32
#define R_ARM_REL32 3
#endif
#ifndef R_ARM_THM_PC22
#define R_ARM_THM_PC22 10
#endif
#ifndef R_ARM_CALL
#define R_ARM_CALL 28
#endif
#ifndef R_ARM_JUMP24
#define R_ARM_JUMP24 29
#endif
#ifndef R_ARM_THM_JUMP24
#define R_ARM_THM_JUMP24 30
#endif
#ifndef R_ARM_MOVW_ABS_NC
#define R_ARM_MOVW_ABS_NC 43
#endif
#ifndef R_ARM_MOVT_ABS
#define R_ARM_MOVT_ABS 44
#endif
#ifndef R_ARM_THM_MOVW_ABS_NC
#define R_ARM_THM_MOVW_ABS_NC 47
#endif
#ifndef R_ARM_THM_MOVT_ABS
#define R_ARM_THM_MOVT_ABS 48
#endif
#ifndef R_ARM_THM_JUMP19
#define R_ARM_THM_JUMP19 51
#endif
#ifndef R_MIPS_32
#define R_MIPS_32 2
#endif
#ifndef R_MIPS_26
#define R_MIPS_26 4
#endif
#ifndef R_MIPS_LO16
#define R_MIPS_LO16 6
#endif
#ifndef R_AARCH64_ABS64
#define R_AARCH64_ABS64 257
#endif
#ifndef R_AARCH64_PREL64
#define R_AARCH64_PREL64 260
#endif
#ifndef EF_ARM_EABI_VERSION
#define EF_ARM_EABI_VERSION(flags) ((flags) & 0xff000000)
#endif
#ifndef EF_ARM_EABI_VER5
#define EF_ARM_EABI_VER5 0x05000000
#endif
#endif
EOF
cat > "${HOST_INCLUDE_DIR}/host-compat.h" <<EOF
#ifndef ARM64VIZ_HOST_COMPAT_H
#define ARM64VIZ_HOST_COMPAT_H
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/types.h>
#include <unistd.h>
#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif
#if !defined(__linux__) && !defined(ARM64VIZ_HAS_COPY_FILE_RANGE)
static inline ssize_t copy_file_range(
  int fd_in,
  off_t *off_in,
  int fd_out,
  off_t *off_out,
  size_t len,
  unsigned int flags
) {
  (void)flags;
  char buffer[65536];
  size_t limit = len < sizeof(buffer) ? len : sizeof(buffer);
  ssize_t nread = off_in ? pread(fd_in, buffer, limit, *off_in) : read(fd_in, buffer, limit);
  if (nread <= 0) {
    return nread;
  }
  ssize_t nwritten = off_out ? pwrite(fd_out, buffer, (size_t)nread, *off_out) : write(fd_out, buffer, (size_t)nread);
  if (nwritten > 0) {
    if (off_in) {
      *off_in += nwritten;
    }
    if (off_out) {
      *off_out += nwritten;
    }
  }
  return nwritten;
}
#endif
#endif
EOF
cat > "${HOST_INCLUDE_DIR}/byteswap.h" <<EOF
#ifndef ARM64VIZ_COMPAT_BYTESWAP_H
#define ARM64VIZ_COMPAT_BYTESWAP_H
#define bswap_16(x) __builtin_bswap16(x)
#define bswap_32(x) __builtin_bswap32(x)
#define bswap_64(x) __builtin_bswap64(x)
#endif
EOF
HOST_FLAGS+=(
  -I"${HOST_INCLUDE_DIR}"
  -I"${SRC_DIR}/tools/include/uapi"
  -I"${SRC_DIR}/tools/include"
  -I"${SRC_DIR}/include/uapi"
  -I"${SRC_DIR}/include"
  -include "${HOST_INCLUDE_DIR}/host-compat.h"
)

KMAKE=(
  make -C "${SRC_DIR}" O="${BUILD_DIR}" ARCH=arm64 LLVM=1 LLVM_IAS=1
  HOSTCC="${HOST_CC}"
  HOSTCXX="${HOST_CXX}"
  HOSTCFLAGS="${HOST_FLAGS[*]}"
  HOSTLDFLAGS="${HOST_LD_FLAGS[*]}"
)

"${KMAKE[@]}" allnoconfig
while IFS= read -r line; do
  case "${line}" in
    "# CONFIG_"*" is not set")
      symbol="${line#"# CONFIG_"}"
      symbol="${symbol%" is not set"}"
      "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" --disable "${symbol}"
      ;;
    "CONFIG_"*"=y")
      symbol="${line#"CONFIG_"}"
      symbol="${symbol%"=y"}"
      "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" --enable "${symbol}"
      ;;
  esac
done < "${SRC_DIR}/arch/arm64/configs/virt.config"

"${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
  --enable EXPERT \
  --enable PRINTK \
  --enable BUG \
  --enable MULTIUSER \
  --enable FUTEX \
  --enable EPOLL \
  --enable SIGNALFD \
  --enable TIMERFD \
  --enable EVENTFD \
  --enable INOTIFY_USER \
  --enable POSIX_TIMERS \
  --enable SYSVIPC \
  --enable BLK_DEV_INITRD \
  --enable BLK_DEV \
  --enable DEVTMPFS \
  --enable DEVTMPFS_MOUNT \
  --enable PROC_FS \
  --enable SYSFS \
  --enable BINFMT_ELF \
  --enable BINFMT_SCRIPT \
  --enable ARM64_HW_AFDBM \
  --enable BLOCK \
  --enable SHMEM \
  --enable TMPFS \
  --enable EXT4_FS \
  --enable JBD2 \
  --enable CRC16 \
  --enable VIRTIO \
  --enable VIRTIO_MENU \
  --enable VIRTIO_MMIO \
  --enable VIRTIO_BLK \
  --enable VIRTIO_INPUT \
  --enable NET \
  --enable PACKET \
  --enable UNIX \
  --enable INET \
  --enable NETDEVICES \
  --enable ETHERNET \
  --enable VIRTIO_NET \
  --enable SMP \
  --set-val NR_CPUS 2 \
  --enable HZ_100 \
  --enable RD_GZIP \
  --enable RD_XZ \
  --enable TTY \
  --enable INPUT_EVDEV \
  --enable VT \
  --enable VT_CONSOLE \
  --enable HW_CONSOLE \
  --enable FB \
  --enable FB_CORE \
  --enable FB_DEVICE \
  --enable FB_SIMPLE \
  --enable FRAMEBUFFER_CONSOLE \
  --enable DRM \
  --enable DRM_KMS_HELPER \
  --enable DRM_VIRTIO_GPU \
  --enable DRM_SIMPLEDRM \
  --enable DRM_FBDEV_EMULATION \
  --enable FONT_SUPPORT \
  --enable FONT_8x16 \
  --enable SERIAL_AMBA_PL011 \
  --enable SERIAL_AMBA_PL011_CONSOLE \
  --disable ACPI \
  --disable ARCH_AIROHA \
  --disable ARCH_AXIADO \
  --disable ARCH_BLAIZE \
  --disable ARCH_CIX \
  --disable ARCH_SOPHGO \
  --disable BPF \
  --disable BPF_SYSCALL \
  --disable ATA \
  --disable BLK_CGROUP \
  --disable CGROUPS \
  --disable CGROUP_DEVICE \
  --disable CGROUP_FREEZER \
  --disable CGROUP_HUGETLB \
  --disable CGROUP_PIDS \
  --disable CGROUP_SCHED \
  --disable COMPAT \
  --disable CRASH_DUMP \
  --disable CRYPTO_MANAGER \
  --disable CRYPTO_TEST \
  --disable DEBUG_INFO \
  --disable DEBUG_KERNEL \
  --disable DEBUG_BUGVERBOSE \
  --disable DEBUG_MISC \
  --disable DEBUG_MEMORY_INIT \
  --disable KALLSYMS \
  --disable AIO \
  --disable AUTOFS_FS \
  --disable BTRFS_FS \
  --disable CONFIGFS_FS \
  --enable COREDUMP \
  --enable ELF_CORE \
  --disable DEBUG_FS \
  --disable FAT_FS \
  --disable FUSE_FS \
  --disable GENERIC_PHY \
  --disable EFI \
  --disable EVENT_TRACING \
  --disable FTRACE \
  --disable FUNCTION_TRACER \
  --disable HIBERNATION \
  --disable IO_URING \
  --disable IO_URING_MOCK_FILE \
  --disable KEXEC \
  --disable KEXEC_FILE \
  --disable KPROBES \
  --disable KVM \
  --disable MEDIA_SUPPORT \
  --disable MEMCG \
  --disable MFD_CORE \
  --disable MMC \
  --disable MODULES \
  --disable NAMESPACES \
  --disable NLS \
  --disable PCI \
  --disable PERF_EVENTS \
  --disable PHY_CADENCE_DPHY \
  --disable PHY_CADENCE_DPHY_RX \
  --disable PHY_CADENCE_SALVO \
  --disable PHY_CADENCE_SIERRA \
  --disable PHY_CADENCE_TORRENT \
  --disable PHY_CAN_TRANSCEIVER \
  --disable PHY_NXP_PTN3222 \
  --disable PHYLIB \
  --disable PINCTRL \
  --disable PM \
  --disable SCHED_AUTOGROUP \
  --disable HZ_250 \
  --disable SCSI \
  --disable SCSI_LOWLEVEL \
  --disable SCSI_UFSHCD \
  --disable SND \
  --disable SND_SOC \
  --disable SOUND \
  --disable PSTORE \
  --disable KEYS \
  --disable OVERLAY_FS \
  --disable SQUASHFS \
  --disable SYSTEM_TRUSTED_KEYRING \
  --disable TRACING \
  --disable UBIFS_FS \
  --disable USB \
  --disable USB_SUPPORT \
  --disable VFAT_FS \
  --disable XEN

"${KMAKE[@]}" olddefconfig

for symbol in ATA AUTOFS_FS BTRFS_FS CGROUPS CONFIGFS_FS DEBUG_FS FUSE_FS GENERIC_PHY GPIOLIB HIBERNATION IO_URING IPMI_HANDLER MMC OVERLAY_FS PCI PINCTRL PSTORE SCSI SND SOUND SQUASHFS UBIFS_FS USB XEN; do
  if grep -q "^CONFIG_${symbol}=y" "${BUILD_DIR}/.config"; then
    echo "Refusing oversized shell kernel config: CONFIG_${symbol}=y" >&2
    exit 1
  fi
done

grep -q '^CONFIG_SMP=y$' "${BUILD_DIR}/.config" || {
  echo 'Refusing kernel config without CONFIG_SMP=y' >&2
  exit 1
}
grep -q '^CONFIG_NR_CPUS=2$' "${BUILD_DIR}/.config" || {
  echo 'Refusing kernel config without CONFIG_NR_CPUS=2' >&2
  exit 1
}
for symbol in BPF_JIT BPF_SYSCALL KALLSYMS; do
  if grep -q "^CONFIG_${symbol}=y" "${BUILD_DIR}/.config"; then
    echo "Refusing debug-heavy kernel config: CONFIG_${symbol}=y" >&2
    exit 1
  fi
done

"${KMAKE[@]}" -j"${JOBS}" Image

cp "${BUILD_DIR}/arch/arm64/boot/Image" "${OUT_DIR}/Image"
cp "${BUILD_DIR}/System.map" "${OUT_DIR}/System.map"
cp "${BUILD_DIR}/.config" "${OUT_DIR}/config"

TRACE_INITRD="${ROOT_DIR}/artifacts/alpine-aarch64/initramfs-virt"
UNCOMPRESSED_INITRD="${OUT_DIR}/initramfs-virt.cpio"
if [[ -f "${TRACE_INITRD}" ]] && gzip -t "${TRACE_INITRD}" 2>/dev/null; then
  gzip -dc "${TRACE_INITRD}" > "${UNCOMPRESSED_INITRD}"
  TRACE_INITRD="${UNCOMPRESSED_INITRD}"
fi

CONSOLE_DEVICES_LIST="${OUT_DIR}/console-devices.list"
CONSOLE_DEVICES_CPIO="${OUT_DIR}/console-devices.cpio"
CONSOLE_INITRD="${OUT_DIR}/initramfs-virt-repacked-console.cpio"
BASE_WITHOUT_INIT_CPIO="${OUT_DIR}/initramfs-virt-without-init.cpio"
TTY_INIT_LIST="${OUT_DIR}/tty-init-overlay.list"
TTY_INIT_OVERLAY="${OUT_DIR}/tty-init-overlay.cpio"
TTY_INITRD="${OUT_DIR}/initramfs-virt-ttyinit.cpio"
MINIMAL_INIT_LIST="${OUT_DIR}/initramfs-minimal-ttyinit.list"
MINIMAL_INITRD="${OUT_DIR}/initramfs-minimal-ttyinit.cpio"
MINIMAL_BUSYBOX="${OUT_DIR}/busybox-minimal"
MINIMAL_MUSL_LOADER="${OUT_DIR}/ld-musl-aarch64.so.1"
GEN_INIT_CPIO="${BUILD_DIR}/usr/gen_init_cpio"
MINIMAL_BUSYBOX_APPLETS=(
  awk basename cat chgrp chmod chown chroot clear cmp cp cut date dd df dirname
  dmesg du echo env false find free grep head hostname id ifconfig init ip kill
  killall less ln login ls md5sum mdev mkdir mknod mount mv nslookup passwd ping
  ping6 printf ps pwd reboot rm rmdir route sed sh sha256sum sleep sort stty sync
  tail tar tee test touch true tty udhcpc umount uname uniq vi wc wget whoami xargs
)

cat > "${CONSOLE_DEVICES_LIST}" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/ttyAMA0 0600 0 0 c 204 64
dir /dev/pts 0755 0 0
EOF
"${GEN_INIT_CPIO}" -t 0 -o "${CONSOLE_DEVICES_CPIO}" "${CONSOLE_DEVICES_LIST}"

cat > "${TTY_INIT_LIST}" <<EOF
file /init ${ROOT_DIR}/scripts/initramfs/arm64viz-console-init 0755 0 0
EOF
"${GEN_INIT_CPIO}" -t 0 -o "${TTY_INIT_OVERLAY}" "${TTY_INIT_LIST}"

bsdtar --format newc --exclude init -cf "${BASE_WITHOUT_INIT_CPIO}" @"${TRACE_INITRD}"
bsdtar --format newc -cf "${CONSOLE_INITRD}" @"${TRACE_INITRD}" @"${CONSOLE_DEVICES_CPIO}"
bsdtar --format newc -cf "${TTY_INITRD}" @"${BASE_WITHOUT_INIT_CPIO}" @"${CONSOLE_DEVICES_CPIO}" @"${TTY_INIT_OVERLAY}"

bsdtar -xOf "${TRACE_INITRD}" usr/bin/busybox > "${MINIMAL_BUSYBOX}"
chmod 0755 "${MINIMAL_BUSYBOX}"
bsdtar -xOf "${TRACE_INITRD}" usr/lib/ld-musl-aarch64.so.1 > "${MINIMAL_MUSL_LOADER}"
chmod 0755 "${MINIMAL_MUSL_LOADER}"
cat > "${MINIMAL_INIT_LIST}" <<EOF
dir /bin 0755 0 0
dir /dev 0755 0 0
dir /dev/pts 0755 0 0
dir /lib 0755 0 0
dir /newroot 0755 0 0
dir /proc 0755 0 0
dir /root 0700 0 0
dir /run 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
file /init ${ROOT_DIR}/scripts/initramfs/arm64viz-console-init 0755 0 0
file /bin/busybox ${MINIMAL_BUSYBOX} 0755 0 0
file /lib/ld-musl-aarch64.so.1 ${MINIMAL_MUSL_LOADER} 0755 0 0
slink /lib/libc.musl-aarch64.so.1 ld-musl-aarch64.so.1 0777 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/ttyAMA0 0600 0 0 c 204 64
EOF
for applet in "${MINIMAL_BUSYBOX_APPLETS[@]}"; do
  printf 'slink /bin/%s busybox 0777 0 0\n' "${applet}" >> "${MINIMAL_INIT_LIST}"
done
"${GEN_INIT_CPIO}" -t 0 -o "${MINIMAL_INITRD}" "${MINIMAL_INIT_LIST}"

cat <<EOF
Built ARM64 shell kernel:
  ${OUT_DIR}/Image
  ${OUT_DIR}/System.map
  ${OUT_DIR}/config
  ${TTY_INITRD}
  ${MINIMAL_INITRD}

Trace it with:
  swift run -c release arm64viz run-linux-trace ${OUT_DIR}/Image \\
    --initrd ${MINIMAL_INITRD} \\
    --memory-mib 512 --minimal-devices --stop-on-el0 \\
    --symbols ${OUT_DIR}/System.map \\
    --exception-storm-threshold 0 --max-steps 300000000 \\
    --bootargs "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/init loglevel=7"
EOF
