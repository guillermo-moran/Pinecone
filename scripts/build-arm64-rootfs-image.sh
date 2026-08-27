#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/artifacts/linux-shell/out"
IMAGE="${1:-${OUT_DIR}/rootfs.ext4}"
SIZE_MIB="${ROOTFS_SIZE_MIB:-auto}"
MINIMUM_SIZE_MIB="${ROOTFS_MIN_SIZE_MIB:-384}"
MINIMUM_FREE_MIB="${ROOTFS_MIN_FREE_MIB:-256}"
MKE2FS="${MKE2FS:-}"
E2FSCK="${E2FSCK:-}"
DUMPE2FS="${DUMPE2FS:-}"
BUSYBOX_APPLETS=(
  awk basename cat chgrp chmod chown chroot clear cmp cp cut date dd df dirname
  dmesg du echo env false find free grep head hexdump hostname id ifconfig init ip kill
  killall less ln ls md5sum mdev mkdir mknod mount mv nslookup passwd ping
  ping6 pgrep printf ps pwd reboot rm rmdir route sed sh sha256sum sleep sort stty sync
  tail tar tee test touch true tty udhcpc umount uname uniq vi wc wget whoami xargs
)

if [[ -z "${MKE2FS}" ]]; then
  if command -v mke2fs >/dev/null 2>&1; then
    MKE2FS="$(command -v mke2fs)"
  elif [[ -x "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs" ]]; then
    MKE2FS="/opt/homebrew/opt/e2fsprogs/sbin/mke2fs"
  elif [[ -x "${HOME}/Library/Android/sdk/platform-tools/mke2fs" ]]; then
    MKE2FS="${HOME}/Library/Android/sdk/platform-tools/mke2fs"
  else
    echo "mke2fs is required to build ${IMAGE}" >&2
    exit 1
  fi
fi

if [[ -z "${E2FSCK}" ]]; then
  if command -v e2fsck >/dev/null 2>&1; then
    E2FSCK="$(command -v e2fsck)"
  elif [[ -x "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck" ]]; then
    E2FSCK="/opt/homebrew/opt/e2fsprogs/sbin/e2fsck"
  else
    echo "e2fsck is required to validate ${IMAGE}" >&2
    exit 1
  fi
fi

if [[ -z "${DUMPE2FS}" ]]; then
  if command -v dumpe2fs >/dev/null 2>&1; then
    DUMPE2FS="$(command -v dumpe2fs)"
  elif [[ -x "/opt/homebrew/opt/e2fsprogs/sbin/dumpe2fs" ]]; then
    DUMPE2FS="/opt/homebrew/opt/e2fsprogs/sbin/dumpe2fs"
  else
    echo "dumpe2fs is required to validate ${IMAGE}" >&2
    exit 1
  fi
fi

if [[ ! -f "${OUT_DIR}/initramfs-virt-ttyinit.cpio" ]]; then
  echo "missing ${OUT_DIR}/initramfs-virt-ttyinit.cpio; run scripts/build-arm64-shell-kernel.sh first" >&2
  exit 1
fi

mkdir -p "${ROOT_DIR}/.build"
WORK_DIR="$(mktemp -d "${ROOT_DIR}/.build/arm64viz-rootfs.XXXXXX")"
ROOTFS_DIR="${WORK_DIR}/root"
IMAGE_STAGING="${IMAGE}.staging.$$"
CHECKSUM_STAGING="${IMAGE}.sha256.staging.$$"
cleanup() {
  rm -rf "${WORK_DIR}"
  rm -f "${IMAGE_STAGING}" "${CHECKSUM_STAGING}"
}
trap cleanup EXIT INT TERM
mkdir -p "${ROOTFS_DIR}"

bsdtar -C "${ROOTFS_DIR}" --exclude dev -xf "${OUT_DIR}/initramfs-virt-ttyinit.cpio"
mkdir -p \
  "${ROOTFS_DIR}/bin" \
  "${ROOTFS_DIR}/dev" \
  "${ROOTFS_DIR}/dev/pts" \
  "${ROOTFS_DIR}/etc/apk" \
  "${ROOTFS_DIR}/etc/init.d" \
  "${ROOTFS_DIR}/etc/network" \
  "${ROOTFS_DIR}/lib/apk/db" \
  "${ROOTFS_DIR}/root" \
  "${ROOTFS_DIR}/root/.config/foot" \
  "${ROOTFS_DIR}/root/.config/gtk-3.0" \
  "${ROOTFS_DIR}/sbin" \
  "${ROOTFS_DIR}/tmp" \
  "${ROOTFS_DIR}/usr/local/bin" \
  "${ROOTFS_DIR}/var/cache/apk" \
  "${ROOTFS_DIR}/var/empty" \
  "${ROOTFS_DIR}/var/lib/apk" \
  "${ROOTFS_DIR}/var/log" \
  "${ROOTFS_DIR}/var/tmp"
chmod 1777 "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/var/tmp"
if [[ "${ARM64VIZ_GRAPHICAL_ROOTFS:-1}" == "1" ]]; then
  export ARM64VIZ_GRAPHICAL_PROFILE="${ARM64VIZ_GRAPHICAL_PROFILE:-phosh}"
  "${ROOT_DIR}/scripts/stage-alpine-graphical-rootfs.sh" "${ROOTFS_DIR}"
  "${ROOT_DIR}/scripts/build-pinecone-pixman.sh" \
    "${OUT_DIR}/libpinecone-pixman.so"
  "${ROOT_DIR}/scripts/build-pinecone-session-launcher.sh" \
    "${OUT_DIR}/pinecone-session-launcher"
  install -m 0755 "${OUT_DIR}/libpinecone-pixman.so" \
    "${ROOTFS_DIR}/usr/lib/libpinecone-pixman.so"
  install -d "${ROOTFS_DIR}/usr/include/pinecone"
  install -m 0644 "${ROOT_DIR}/scripts/rootfs/pinecone-pixman.h" \
    "${ROOTFS_DIR}/usr/include/pinecone/pinecone-pixman.h"
  if [[ "${PINECONE_REUSE_PIXMAN_LIBRARY:-0}" != "1" ]]; then
    "${ROOT_DIR}/scripts/build-pinecone-pixman-library.sh" \
      "${OUT_DIR}/libpixman-1.so.0.46.4"
  elif [[ ! -x "${OUT_DIR}/libpixman-1.so.0.46.4" ]]; then
    echo "missing reusable ${OUT_DIR}/libpixman-1.so.0.46.4" >&2
    exit 1
  fi
  install -m 0755 "${OUT_DIR}/libpixman-1.so.0.46.4" \
    "${ROOTFS_DIR}/usr/lib/libpixman-1.so.0.46.4"
  OPTIONAL_DBUS_SERVICES="${ROOTFS_DIR}/usr/share/pinecone/dbus-system-services"
  mkdir -p "${OPTIONAL_DBUS_SERVICES}"
  for service in org.freedesktop.UPower.service; do
    active_service="${ROOTFS_DIR}/usr/share/dbus-1/system-services/${service}"
    if [[ -f "${active_service}" ]]; then
      mv "${active_service}" "${OPTIONAL_DBUS_SERVICES}/${service}"
    fi
  done

  # feedbackd takes the session bus activation path during Phosh startup, but
  # this compact guest does not provide the hardware feedback service it needs
  # to become useful. Leaving its activator installed makes Phosh wait for the
  # D-Bus 120-second service-start timeout. Keep the descriptor available for
  # a future supervised feedback stack while making the default failure
  # immediate and deterministic.
  OPTIONAL_SESSION_SERVICES="${ROOTFS_DIR}/usr/share/pinecone/dbus-session-services"
  mkdir -p "${OPTIONAL_SESSION_SERVICES}"
  FEEDBACK_SERVICE="${ROOTFS_DIR}/usr/share/dbus-1/services/org.sigxcpu.Feedback.service"
  if [[ -f "${FEEDBACK_SERVICE}" ]]; then
    mv "${FEEDBACK_SERVICE}" "${OPTIONAL_SESSION_SERVICES}/"
  fi

  # Alpine marks these applications as D-Bus activatable. Under interpreted
  # execution a failed activation holds Phosh on an empty launch surface until
  # dbus-daemon's 120-second timeout. Direct desktop launches still use each
  # application's normal GApplication single-instance protocol, but report
  # startup failures immediately and keep stderr in the Phosh session log.
  for desktop_name in \
    dev.tchx84.Portfolio.desktop \
    org.gnome.Calculator.desktop \
    org.gnome.Calendar.desktop \
    org.gnome.Settings.desktop \
    org.gnome.TextEditor.desktop \
    org.gnome.clocks.desktop; do
    desktop_file="${ROOTFS_DIR}/usr/share/applications/${desktop_name}"
    if [[ -f "${desktop_file}" ]]; then
      sed -i.bak 's/^DBusActivatable=true$/DBusActivatable=false/' \
        "${desktop_file}"
      rm -f "${desktop_file}.bak"
    fi
  done
  SETTINGS_DESKTOP="${ROOTFS_DIR}/usr/share/applications/org.gnome.Settings.desktop"
  if [[ -f "${SETTINGS_DESKTOP}" ]]; then
    sed -i.bak \
      's|^Exec=.*$|Exec=/usr/local/bin/pinecone-launch-settings|' \
      "${SETTINGS_DESKTOP}"
    rm -f "${SETTINGS_DESKTOP}.bak"
  fi
  mkdir -p "${ROOTFS_DIR}/usr/share/pinecone"
  cat > "${ROOTFS_DIR}/usr/share/pinecone/phosh-apps.list" <<'EOF'
# Prevalidated first-boot launcher set. Patched Phosh uses normal dynamic
# discovery after any desktop-file change, including applications added by apk.
foot.desktop
dev.tchx84.Portfolio.desktop
org.gnome.Calculator.desktop
org.gnome.Calendar.desktop
org.gnome.clocks.desktop
org.gnome.TextEditor.desktop
org.gnome.Settings.desktop
EOF
  SCHEMA_DIR="${ROOTFS_DIR}/usr/share/glib-2.0/schemas"
  if [[ -d "${SCHEMA_DIR}" ]]; then
    cat > "${SCHEMA_DIR}/99-pinecone.gschema.override" <<'EOF'
[org.gnome.desktop.session]
idle-delay=uint32 0

[org.gnome.desktop.screensaver]
lock-enabled=false
picture-options='none'
picture-uri=''
primary-color='#000000'
secondary-color='#000000'
color-shading-type='solid'

[org.gnome.desktop.background]
picture-options='none'
picture-uri=''
picture-uri-dark=''
primary-color='#000000'
secondary-color='#000000'
color-shading-type='solid'

[org.gnome.desktop.interface]
enable-animations=false
toolkit-accessibility=false

[sm.puri.phosh.lockscreen]
require-unlock=false

[sm.puri.phosh]
favorites=['foot.desktop', 'dev.tchx84.Portfolio.desktop', 'org.gnome.Calculator.desktop', 'org.gnome.TextEditor.desktop']
force-adaptive=['foot.desktop', 'dev.tchx84.Portfolio.desktop', 'org.gnome.Calculator.desktop', 'org.gnome.Calendar.desktop', 'org.gnome.clocks.desktop', 'org.gnome.TextEditor.desktop']
EOF
    if ! command -v glib-compile-schemas >/dev/null 2>&1; then
      echo "glib-compile-schemas is required for graphical rootfs profiles" >&2
      exit 1
    fi
    glib-compile-schemas "${SCHEMA_DIR}"
  fi
  MIME_DIR="${ROOTFS_DIR}/usr/share/mime"
  if [[ -d "${MIME_DIR}/packages" ]]; then
    if ! command -v update-mime-database >/dev/null 2>&1; then
      echo "update-mime-database is required for graphical rootfs profiles" >&2
      exit 1
    fi
    update-mime-database "${MIME_DIR}"
  fi

  # GTK icon caches are platform-independent. Use a host utility when present;
  # builders without GTK still produce a valid image and can supply the tool
  # explicitly through GTK_UPDATE_ICON_CACHE.
  GTK_ICON_CACHE_TOOL="${GTK_UPDATE_ICON_CACHE:-$(command -v gtk-update-icon-cache || true)}"
  if [[ -n "${GTK_ICON_CACHE_TOOL}" ]]; then
    for theme_dir in "${ROOTFS_DIR}"/usr/share/icons/*; do
      [[ -f "${theme_dir}/index.theme" ]] || continue
      "${GTK_ICON_CACHE_TOOL}" --force --ignore-theme-index "${theme_dir}"
    done
  fi

  PHOSH_DESKTOP="${ROOTFS_DIR}/usr/share/applications/mobi.phosh.Shell.desktop"
  if [[ -f "${PHOSH_DESKTOP}" ]]; then
    # Phosh registers with gnome-session only after its shell managers finish
    # initializing. That exceeds gnome-session's fixed startup-notification
    # deadline under interpretation, even though Phosh subsequently becomes
    # ready. Keep process supervision, but do not make readiness notification a
    # prerequisite for the session to remain alive.
    PHOSH_DESKTOP_TMP="${PHOSH_DESKTOP}.pinecone"
    awk '
      $0 == "X-GNOME-Autostart-Notify=true" {
        print "X-GNOME-Autostart-Notify=false"
        replaced = 1
        next
      }
      { print }
      END { if (!replaced) exit 1 }
    ' "${PHOSH_DESKTOP}" > "${PHOSH_DESKTOP_TMP}"
    chmod --reference="${PHOSH_DESKTOP}" "${PHOSH_DESKTOP_TMP}" 2>/dev/null || \
      chmod 0644 "${PHOSH_DESKTOP_TMP}"
    mv "${PHOSH_DESKTOP_TMP}" "${PHOSH_DESKTOP}"

    # A required GNOME session component is subject to a fixed startup
    # deadline even when startup notification is disabled. Phosh can exceed
    # that deadline under interpretation, after which gnome-session marks the
    # otherwise healthy shell as a fatal failure. Start Phosh and the OSK as
    # ordinary supervised autostart applications in a Pinecone-specific
    # session instead.
    mkdir -p \
      "${ROOTFS_DIR}/etc/xdg/autostart" \
      "${ROOTFS_DIR}/usr/share/gnome-session/sessions"
    # Alpine marks the packaged entry as systemd-only. Pinecone intentionally
    # uses gnome-session's process backend because the compact guest does not
    # run systemd, so install an explicit non-systemd autostart entry.
    sed \
      -e '/^X-GNOME-HiddenUnderSystemd=/d' \
      -e 's/^X-GNOME-Autostart-Notify=true$/X-GNOME-Autostart-Notify=false/' \
      "${PHOSH_DESKTOP}" > \
      "${ROOTFS_DIR}/etc/xdg/autostart/mobi.phosh.Shell.desktop"

    PINECONE_SESSION="${ROOTFS_DIR}/usr/share/gnome-session/sessions/pinecone-phosh.session"
    cat > "${PINECONE_SESSION}" <<'EOF'
[GNOME Session]
Name=Pinecone Phosh
# Phosh and the OSK are supervised autostart applications. Keeping this list
# empty prevents optional GNOME daemons from becoming fatal dependencies on a
# minimal non-systemd guest (for example, Power without UPower/logind).
RequiredComponents=
EOF

    OSK_DESKTOP="${ROOTFS_DIR}/usr/share/applications/sm.puri.OSK0.desktop"
    if [[ -f "${OSK_DESKTOP}" ]]; then
      sed 's/^X-GNOME-Autostart-Notify=true$/X-GNOME-Autostart-Notify=false/' \
        "${OSK_DESKTOP}" > \
        "${ROOTFS_DIR}/etc/xdg/autostart/sm.puri.OSK0.desktop"
    fi
  fi

  # Alpine's packaged Phoc profile targets an x86 QXL virtual display and
  # forces Virtual-1 to 720x1440 at scale 2. Pinecone's virtio-gpu advertises
  # a native 480x1024 panel; using the QXL mode puts Phosh's layer surfaces on
  # the wrong output geometry and leaves the host scanout black.
  mkdir -p "${ROOTFS_DIR}/etc/phosh"
  cat > "${ROOTFS_DIR}/etc/phosh/phoc.ini" <<'EOF'
[output:Virtual-1]
mode = 480x1024
scale = 1
EOF

  mkdir -p "${ROOTFS_DIR}/etc/udev/rules.d"
  cat > "${ROOTFS_DIR}/etc/udev/rules.d/70-pinecone-input.rules" <<'EOF'
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Pinecone Touchscreen", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1", ENV{ID_SEAT}="seat0"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Pinecone Keyboard", ENV{ID_INPUT}="1", ENV{ID_INPUT_KEYBOARD}="1", ENV{ID_SEAT}="seat0"
EOF

  # The guest owns eth0 directly through its lightweight static setup. Keep
  # NetworkManager from replacing that configuration while still exposing the
  # system D-Bus API expected by Phosh and GNOME Settings.
  mkdir -p "${ROOTFS_DIR}/etc/NetworkManager/conf.d"
  cat > "${ROOTFS_DIR}/etc/NetworkManager/conf.d/10-pinecone.conf" <<'EOF'
[main]
plugins=keyfile
no-auto-default=*

[keyfile]
unmanaged-devices=interface-name:eth0
EOF

  # This compact session does not run gnome-settings-daemon, so changing
  # org.gnome.desktop.interface alone never reaches GtkSettings. Phosh and
  # libhandy would otherwise execute their lock-screen transitions one
  # interpreted frame at a time, exposing partially clipped damage for
  # minutes. Apply the toolkit setting before either process starts.
  cat > "${ROOTFS_DIR}/root/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-enable-animations=false
EOF
  cp "${ROOT_DIR}/scripts/rootfs/pinecone-gtk.css" \
    "${ROOTFS_DIR}/root/.config/gtk-3.0/gtk.css"
fi
# Alpine packages can replace top-level directory entries while unpacking.
# Install the boot-critical init and BusyBox links after the package overlay.
if [[ ! -e "${ROOTFS_DIR}/bin/busybox" && -e "${ROOTFS_DIR}/usr/bin/busybox" ]]; then
  ln -sf /usr/bin/busybox "${ROOTFS_DIR}/bin/busybox"
fi
for applet in "${BUSYBOX_APPLETS[@]}"; do
  ln -sf busybox "${ROOTFS_DIR}/bin/${applet}"
done
cp "${ROOT_DIR}/scripts/rootfs/arm64viz-root-init" "${ROOTFS_DIR}/sbin/init"
chmod 0755 "${ROOTFS_DIR}/sbin/init"
mkdir -p \
  "${ROOTFS_DIR}/lib/apk/db" \
  "${ROOTFS_DIR}/var/cache/apk" \
  "${ROOTFS_DIR}/var/lib/apk" \
  "${ROOTFS_DIR}/var/log"
cat > "${ROOTFS_DIR}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
messagebus:x:101:101:D-Bus system message bus:/run/dbus:/sbin/nologin
polkitd:x:102:102:PolicyKit daemon:/var/empty:/sbin/nologin
malcontent-webd:x:106:106:Malcontent web service:/var/empty:/sbin/nologin
malcontent-timerd:x:107:107:Malcontent timer service:/var/empty:/sbin/nologin
malcontent-timer-ext-agent:x:108:108:Malcontent timer agent:/var/empty:/sbin/nologin
colord:x:103:103:Color management daemon:/var/lib/colord:/sbin/nologin
geoclue:x:104:104:Geolocation service:/var/lib/geoclue:/sbin/nologin
nobody:x:65534:65534:nobody:/var/empty:/bin/false
EOF
cat > "${ROOTFS_DIR}/etc/group" <<EOF
root:x:0:
tty:x:5:
disk:x:6:
lp:x:7:
kmem:x:9:
wheel:x:10:root
audio:x:18:
cdrom:x:19:
dialout:x:20:
tape:x:26:
users:x:100:
video:x:27:root
input:x:28:root
kvm:x:34:
messagebus:x:101:
polkitd:x:102:
malcontent-webd:x:106:
malcontent-timerd:x:107:
malcontent-timer-ext-agent:x:108:
colord:x:103:
geoclue:x:104:
nobody:x:65534:
EOF
cat > "${ROOTFS_DIR}/etc/shadow" <<EOF
root::0:0:99999:7:::
messagebus:!:0:0:99999:7:::
polkitd:!:0:0:99999:7:::
malcontent-webd:!:0:0:99999:7:::
malcontent-timerd:!:0:0:99999:7:::
malcontent-timer-ext-agent:!:0:0:99999:7:::
colord:!:0:0:99999:7:::
geoclue:!:0:0:99999:7:::
nobody:*:0:0:99999:7:::
EOF
chmod 0600 "${ROOTFS_DIR}/etc/shadow"
mkdir -p "${ROOTFS_DIR}/etc/pam.d"
cat > "${ROOTFS_DIR}/etc/pam.d/login" <<'EOF'
#%PAM-1.0
auth       sufficient pam_rootok.so
auth       include    base-auth
account    include    base-account
password   include    base-password
session    include    base-session
session    optional   pam_elogind.so
EOF
cat > "${ROOTFS_DIR}/etc/profile" <<'EOF'
export PATH=/usr/local/bin:/bin:/sbin:/usr/bin:/usr/sbin
export PAGER=less
export EDITOR=vi
export TERM="${TERM:-dumb}"
export PS1='arm64viz-root:\w# '
alias ll='ls -la'
EOF
cat > "${ROOTFS_DIR}/root/.profile" <<'EOF'
[ -f /etc/profile ] && . /etc/profile
cd /root 2>/dev/null || true
EOF
cat > "${ROOTFS_DIR}/root/.config/foot/foot.ini" <<'EOF'
[main]
font=DejaVu Sans Mono:size=18
dpi-aware=no
pad=8x8

[colors-dark]
background=202020
foreground=f2f2f2
EOF
cat > "${ROOTFS_DIR}/usr/local/bin/pinecone-input-test" <<'EOF'
#!/bin/sh
set -eu

for sys_event in /sys/class/input/event*; do
  [ -e "$sys_event" ] || continue
  event_name="$(cat "$sys_event/device/name" 2>/dev/null || true)"
  case "$event_name" in
    *Pinecone*Touchscreen*)
      event_device="/dev/input/${sys_event##*/}"
      printf 'pinecone-input: touchscreen=%s name=%s\n' "$event_device" "$event_name" >&2
      exec evtest "$event_device"
      ;;
  esac
done

printf 'pinecone-input: touchscreen event device not found\n' >&2
exit 1
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/pinecone-input-test"
cat > "${ROOTFS_DIR}/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS
ttyAMA0::respawn:/sbin/getty -L ttyAMA0 115200 dumb
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
cat > "${ROOTFS_DIR}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
mkdir -p /run
if ! grep -qs ' /run ' /proc/mounts; then
  mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run 2>/dev/null || true
fi
mkdir -p /run/dbus /run/user/0
chmod 0700 /run/user/0
if [ ! -S /run/dbus/system_bus_socket ] && command -v dbus-daemon >/dev/null 2>&1; then
  dbus-daemon --system --fork --nopidfile
fi
if [ -x /sbin/udevd ] && [ -x /sbin/udevadm ]; then
  /sbin/udevd --daemon 2>/dev/null || true
  /sbin/udevadm trigger --subsystem-match=input --action=add >/dev/null 2>&1 &
fi
/bin/ifconfig lo 127.0.0.1 up 2>/dev/null || true
for _ in 1 2 3 4 5; do
  [ -e /sys/class/net/eth0 ] && break
  /bin/sleep 1
done
[ -e /sys/class/net/eth0 ] && /bin/ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null || true
[ -e /sys/class/net/eth0 ] && /bin/route add default gw 10.0.2.2 eth0 2>/dev/null || true
EOF
chmod 0755 "${ROOTFS_DIR}/etc/init.d/rcS"
cat > "${ROOTFS_DIR}/etc/hostname" <<EOF
arm64viz
EOF
cat > "${ROOTFS_DIR}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 arm64viz.local arm64viz
::1 localhost ip6-localhost
EOF
cat > "${ROOTFS_DIR}/etc/fstab" <<'EOF'
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devpts /dev/pts devpts defaults 0 0
tmpfs /tmp tmpfs mode=1777 0 0
EOF
cat > "${ROOTFS_DIR}/etc/mdev.conf" <<'EOF'
null root:root 666
console root:root 600
ttyAMA0 root:root 600
event[0-9]+ root:input 660
card[0-9]+ root:video 660
renderD[0-9]+ root:video 660
EOF
cat > "${ROOTFS_DIR}/usr/local/bin/start-pinecone-ui" <<'EOF'
#!/bin/sh
set -eu
mkdir -p /run/user/0
chmod 0700 /run/user/0
export XDG_RUNTIME_DIR=/run/user/0
export WLR_BACKENDS=drm
export WLR_RENDERER=pixman
export WLR_LOG="${PINECONE_WLR_LOG:-0}"
export XKB_DEFAULT_LAYOUT=us
ulimit -c unlimited
if [ -e /proc/sys/kernel/core_pattern ]; then
  echo '/var/log/core.%e.%p' > /proc/sys/kernel/core_pattern
fi
export LIBSEAT_BACKEND=noop
for sys_event in /sys/class/input/event*; do
  [ -e "$sys_event" ] || continue
  event_name="$(cat "$sys_event/device/name" 2>/dev/null || true)"
  printf 'pinecone-ui: input=%s name=%s\n' "/dev/input/${sys_event##*/}" "$event_name" >&2
done
set +e
cage -- foot
CAGE_STATUS=$?
set -e
printf 'pinecone-ui: cage exited with status %s\n' "$CAGE_STATUS" >&2
for CORE in /var/log/core.*; do
  if [ -e "$CORE" ]; then
    ls -l "$CORE" >&2
  fi
done
exit "$CAGE_STATUS"
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/start-pinecone-ui"
cat > "${ROOTFS_DIR}/usr/local/bin/pinecone-session-env" <<'EOF'
#!/bin/sh
mkdir -p /run/user/0 /run/dbus
chmod 0700 /run/user/0
export XDG_RUNTIME_DIR=/run/user/0
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=Phosh:GNOME
export WLR_BACKENDS=drm
export WLR_RENDERER=pixman
export WLR_LOG="${PINECONE_WLR_LOG:-0}"
export XKB_DEFAULT_LAYOUT=us
export LIBSEAT_BACKEND=noop
# GTK otherwise activates org.a11y.Bus on first widget construction. This
# compact session does not start the AT-SPI bus, and D-Bus waits 120 seconds
# before failing that activation. Keep accessibility opt-in until Pinecone has
# a supervised accessibility service stack.
if [ "${PINECONE_ENABLE_ACCESSIBILITY:-0}" != "1" ]; then
  export NO_AT_BRIDGE=1
  export GTK_A11Y=none
fi
ulimit -c unlimited
mkdir -p /var/log
if [ -e /proc/sys/kernel/core_pattern ]; then
  echo '/var/log/core.%e.%p' > /proc/sys/kernel/core_pattern
fi

pinecone_start_system_bus()
{
  if ! command -v dbus-daemon >/dev/null 2>&1; then
    echo 'pinecone-session: dbus-daemon is not installed' >&2
    return 1
  fi
  if command -v dbus-send >/dev/null 2>&1 &&
     dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
       / org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    return 0
  fi
  rm -f /run/dbus/system_bus_socket /run/dbus/pid
  mkdir -p /run/dbus
  dbus-daemon --system --fork --nopidfile
}

pinecone_configure_optional_system_services()
{
  active_dir=/usr/share/dbus-1/system-services
  optional_dir=/usr/share/pinecone/dbus-system-services
  for service in org.freedesktop.UPower.service; do
    if [ "${PINECONE_ENABLE_SYSTEM_SERVICES:-0}" = "1" ]; then
      [ ! -f "$optional_dir/$service" ] || \
        cp "$optional_dir/$service" "$active_dir/$service"
    else
      rm -f "$active_dir/$service"
    fi
  done
}

pinecone_prepare_input()
{
  if [ ! -x /sbin/udevd ] || [ ! -x /sbin/udevadm ]; then
    echo 'pinecone-session: eudev is not installed' >&2
    return 1
  fi

  mkdir -p /run/udev
  if [ ! -s /run/udev/udevd.pid ] ||
     ! kill -0 "$(cat /run/udev/udevd.pid 2>/dev/null)" 2>/dev/null; then
    rm -f /run/udev/udevd.pid
    /sbin/udevd --daemon
  fi

  # The root filesystem already inherits devtmpfs from the initramfs. Process
  # only input add events here so libinput gets its udev tags without paying
  # for a full interpreted-device scan on every graphical session.
  /sbin/udevadm trigger --subsystem-match=input --action=add
  /sbin/udevadm settle --timeout=10

  for database in /run/udev/data/c13:*; do
    [ -f "$database" ] || continue
    if grep -q '^E:ID_INPUT_TOUCHSCREEN=1$' "$database"; then
      return 0
    fi
  done
  echo 'pinecone-session: touchscreen was not tagged for libinput' >&2
  return 1
}
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/pinecone-session-env"
cat > "${ROOTFS_DIR}/usr/local/bin/start-pinecone-phoc" <<'EOF'
#!/bin/sh
set -eu
. /usr/local/bin/pinecone-session-env

if ! command -v phoc >/dev/null 2>&1; then
  echo 'pinecone-phoc: phoc is not installed; use the phoc graphical profile' >&2
  exit 127
fi

if command -v dbus-uuidgen >/dev/null 2>&1; then
  dbus-uuidgen --ensure 2>/dev/null || true
fi
pinecone_start_system_bus || \
  echo 'pinecone-phoc: system bus unavailable; continuing with session bus' >&2
pinecone_prepare_input || echo 'pinecone-phoc: input discovery unavailable' >&2

echo 'pinecone-phoc: starting compositor at 480x1024' >&2
set +e
dbus-run-session -- phoc -E foot
PHOC_STATUS=$?
set -e
printf 'pinecone-phoc: compositor exited with status %s\n' "$PHOC_STATUS" >&2
for CORE in /var/log/core.phoc.*; do
  [ -e "$CORE" ] && ls -l "$CORE" >&2
done
exit "$PHOC_STATUS"
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/start-pinecone-phoc"
cat > "${ROOTFS_DIR}/usr/local/bin/start-pinecone-wayland-test" <<'EOF'
#!/bin/sh
set -eu
. /usr/local/bin/pinecone-session-env

if ! command -v weston-simple-shm >/dev/null 2>&1; then
  echo 'pinecone-wayland-test: weston-simple-shm is not installed' >&2
  exit 127
fi

echo 'pinecone-wayland-test: starting shared-memory client at 480x1024' >&2
exec dbus-run-session -- phoc -E weston-simple-shm
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/start-pinecone-wayland-test"
cp "${ROOT_DIR}/scripts/rootfs/pinecone-phosh-client" \
  "${ROOTFS_DIR}/usr/local/bin/pinecone-phosh-client"
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/pinecone-phosh-client"
cat > "${ROOTFS_DIR}/usr/local/bin/start-pinecone-phosh" <<'EOF'
#!/bin/sh
set -eu
. /usr/local/bin/pinecone-session-env

if ! command -v phoc >/dev/null 2>&1 ||
   ! command -v gnome-session >/dev/null 2>&1 ||
   [ ! -x /usr/libexec/phosh ]; then
  echo 'pinecone-phosh: phoc, phosh, or gnome-session is not installed; use the phosh graphical profile' >&2
  exit 127
fi

if command -v dbus-uuidgen >/dev/null 2>&1; then
  dbus-uuidgen --ensure 2>/dev/null || true
fi
pinecone_configure_optional_system_services
pinecone_start_system_bus || echo 'pinecone-phosh: system bus unavailable' >&2
pinecone_prepare_input || echo 'pinecone-phosh: input discovery unavailable' >&2

CACHE_STAMP=/var/cache/pinecone/graphical-runtime-v5
if [ ! -e "$CACHE_STAMP" ]; then
  echo 'pinecone-phosh: preparing required graphical metadata' >&2
  mkdir -p /var/cache/pinecone
  # MIME metadata is generated while constructing the image. Fontconfig and
  # GTK can validate their package-provided caches lazily; forcing complete
  # rebuilds here delays the first frame by billions of interpreted guest
  # instructions. Only the loader registry is required synchronously.
  if command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
    mkdir -p /usr/lib/gdk-pixbuf-2.0/2.10.0
    gdk-pixbuf-query-loaders > /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache || true
  fi
  if command -v gdk-pixbuf-csource >/dev/null 2>&1 &&
     ! gdk-pixbuf-csource \
       /usr/share/icons/Adwaita/scalable/status/image-missing.svg \
       >/dev/null 2>&1; then
    echo 'pinecone-phosh: SVG image loader preflight failed' >&2
    exit 1
  fi
  touch "$CACHE_STAMP"
fi

echo 'pinecone-phosh: starting mobile shell at 480x1024' >&2
if ! grep -q ' /dev/shm tmpfs ' /proc/mounts 2>/dev/null; then
  echo 'pinecone-phosh: /dev/shm is not backed by tmpfs' >&2
  exit 1
fi
SHM_PROBE="/dev/shm/.pinecone-probe.$$"
if ! (umask 077; : > "$SHM_PROBE") 2>/dev/null; then
  echo 'pinecone-phosh: shared-memory allocation is unavailable' >&2
  exit 1
fi
rm -f "$SHM_PROBE"
if ! find /sys/class/drm -maxdepth 1 -name 'card*' -print -quit 2>/dev/null | grep -q . &&
   command -v modprobe >/dev/null 2>&1; then
  modprobe virtio_gpu 2>/dev/null || true
fi
if ! find /sys/class/drm -maxdepth 1 -name 'card*' -print -quit 2>/dev/null | grep -q .; then
  echo 'pinecone-phosh: no DRM scanout device is available' >&2
  exit 1
fi
export WLR_BACKENDS=drm,libinput
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=pixman
export WLR_RENDERER_ALLOW_SOFTWARE=1
export _GNOME_SESSION_ACCELERATED=1
export _GNOME_IS_SOFTWARE_RENDERING=1
export _GNOME_SESSION_RENDERER=pixman
export GSK_RENDERER=cairo
export LD_PRELOAD=/usr/lib/libpinecone-pixman.so
export PINECONE_PIXMAN_DIAGNOSTICS=${PINECONE_PIXMAN_DIAGNOSTICS:-0}
# virtio-gpu exposes a virtual connector. Phosh must treat that connector as
# the device's built-in panel so it can select a primary mobile monitor.
export PHOSH_DEBUG=fake-builtin
# Pinecone composites each flushed rectangle into a persistent scanout, so
# Phoc's partial damage is safe across rotating dumb buffers. Keep transitions
# disabled, but do not turn small touch updates into full-screen Pixman work.
export PHOC_DEBUG=disable-animations
set +e
mkdir -p /var/log/pinecone
PHOC_INI=/usr/share/phosh/phoc.ini
if [ -f /etc/phosh/phoc.ini ]; then
  PHOC_INI=/etc/phosh/phoc.ini
fi
# Keep compositor and shell logs separate. Do not request Phoc's opaque startup
# shield: interpreted guests can take minutes to initialize Phosh, and a shield
# would replace otherwise valid DRM output with an indistinguishable black VM.
PHOC_VERBOSE=
if [ "${PINECONE_PHOC_VERBOSE:-0}" = "1" ]; then
  PHOC_VERBOSE=-v
fi
dbus-run-session -- phoc ${PHOC_VERBOSE} -C "$PHOC_INI" \
  -E /usr/local/bin/pinecone-phosh-client \
  > /var/log/pinecone/phoc.log 2>&1
SESSION_STATUS=$?
cat /var/log/pinecone/phoc.log
cat /var/log/pinecone/phosh-session.log 2>/dev/null || true
set -e
printf 'pinecone-phosh: session exited with status %s\n' "$SESSION_STATUS" >&2
for CORE in /var/log/core.phoc.* /var/log/core.phosh.* /var/log/core.gnome-session.*; do
  [ -e "$CORE" ] && ls -l "$CORE" >&2
done
exit "$SESSION_STATUS"
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/bin/start-pinecone-phosh"
install -m 0755 "${OUT_DIR}/pinecone-session-launcher" \
  "${ROOTFS_DIR}/usr/local/bin/pinecone-session-launcher"
ln -sf pinecone-session-launcher \
  "${ROOTFS_DIR}/usr/local/bin/start-pinecone-phosh"
ln -sf pinecone-session-launcher \
  "${ROOTFS_DIR}/usr/local/bin/pinecone-phosh-client"
ln -sf pinecone-session-launcher \
  "${ROOTFS_DIR}/usr/local/bin/pinecone-launch-settings"
cat > "${ROOTFS_DIR}/etc/shells" <<'EOF'
/bin/sh
/bin/ash
EOF
cat > "${ROOTFS_DIR}/etc/resolv.conf" <<'EOF'
nameserver 10.0.2.3
options timeout:1 attempts:3
EOF
cat > "${ROOTFS_DIR}/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
	address 10.0.2.15
	netmask 255.255.255.0
	gateway 10.0.2.2
EOF
cat > "${ROOTFS_DIR}/etc/apk/repositories" <<'EOF'
http://dl-cdn.alpinelinux.org/alpine/edge/main
http://dl-cdn.alpinelinux.org/alpine/edge/community
EOF
cat > "${ROOTFS_DIR}/etc/apk/arch" <<'EOF'
aarch64
EOF
touch \
  "${ROOTFS_DIR}/lib/apk/db/installed" \
  "${ROOTFS_DIR}/lib/apk/db/lock" \
  "${ROOTFS_DIR}/lib/apk/db/scripts.tar" \
  "${ROOTFS_DIR}/etc/apk/world"
cat > "${ROOTFS_DIR}/etc/arm64viz-release" <<EOF
NAME=arm64viz-rootfs
ID=arm64viz
VERSION=0.1
EOF
cat > "${ROOTFS_DIR}/root/README" <<EOF
This is the first persistent arm64viz Linux root filesystem.

The initramfs mounts this image from /dev/vda and switch_roots into /sbin/init.
Files written here are backed by the virtual block device.
EOF

mkdir -p "$(dirname "${IMAGE}")"
STAGED_KIB="$(du -sk "${ROOTFS_DIR}" | awk '{print $1}')"
STAGED_MIB="$(( (STAGED_KIB + 1023) / 1024 ))"
# Leave room for ext4 metadata and package downloads/installation. Graphical
# profiles vary substantially as Alpine packages change, so a fixed image size
# is not reliable.
REQUIRED_MIB="$(( ((STAGED_MIB + MINIMUM_FREE_MIB) * 110 + 99) / 100 ))"
if (( REQUIRED_MIB < MINIMUM_SIZE_MIB )); then
  REQUIRED_MIB="${MINIMUM_SIZE_MIB}"
fi
if [[ "${SIZE_MIB}" == "auto" ]]; then
  SIZE_MIB="${REQUIRED_MIB}"
elif (( SIZE_MIB < REQUIRED_MIB )); then
  echo "ROOTFS_SIZE_MIB=${SIZE_MIB} is too small for ${STAGED_MIB} MiB of staged files." >&2
  echo "Use ROOTFS_SIZE_MIB=${REQUIRED_MIB} or larger." >&2
  exit 1
fi
mkdir -p "$(dirname "${IMAGE}")"
rm -f "${IMAGE_STAGING}" "${CHECKSUM_STAGING}"
truncate -s "${SIZE_MIB}M" "${IMAGE_STAGING}"
# The VM does not expose a battery-backed wall clock yet. Normalize staged
# mtimes so fontconfig and other cache validators do not reject every cache as
# being newer than the guest clock on each boot.
find "${ROOTFS_DIR}" -exec touch -h -t 197001010000.00 {} +
if [[ "${ARM64VIZ_GRAPHICAL_ROOTFS:-1}" == "1" ]]; then
  # Rebuild timestamp-sensitive caches only after source directories have
  # their final mtimes. The cache payloads are generated by the staged ARM64
  # binaries, avoiding host-endian or host-module-path artifacts.
  GTK_ICON_CACHE_TOOL="${GTK_UPDATE_ICON_CACHE:-$(command -v gtk-update-icon-cache || true)}"
  if [[ -n "${GTK_ICON_CACHE_TOOL}" ]]; then
    for theme_dir in "${ROOTFS_DIR}"/usr/share/icons/*; do
      [[ -f "${theme_dir}/index.theme" ]] || continue
      "${GTK_ICON_CACHE_TOOL}" --force --ignore-theme-index "${theme_dir}"
    done
  fi
  "${ROOT_DIR}/scripts/generate-aarch64-rootfs-caches.sh" "${ROOTFS_DIR}"
fi
# Keep the journal, but materialize allocation metadata before publication.
# Deferred block/inode initialization exercises SMP paths before userspace is
# available and previously exposed partially initialized groups to the guest.
"${MKE2FS}" -q -t ext4 \
  -O ^metadata_csum,^uninit_bg \
  -E lazy_itable_init=0,lazy_journal_init=0 \
  -L arm64viz-root \
  -d "${ROOTFS_DIR}" \
  "${IMAGE_STAGING}"

# Never publish an image unless the ext4 metadata is internally consistent.
# -n keeps validation read-only; -f checks every group even for a clean image.
if ! "${E2FSCK}" -fn "${IMAGE_STAGING}" > "${WORK_DIR}/e2fsck.log" 2>&1; then
  cat "${WORK_DIR}/e2fsck.log" >&2
  echo "error: staged root filesystem failed validation" >&2
  exit 1
fi

if "${DUMPE2FS}" "${IMAGE_STAGING}" 2>/dev/null | \
   grep -Eq 'INODE_UNINIT|BLOCK_UNINIT'; then
  echo "error: staged root filesystem contains deferred block-group metadata" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "${IMAGE_STAGING}" | awk '{ print $1 }' > "${CHECKSUM_STAGING}"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${IMAGE_STAGING}" | awk '{ print $1 }' > "${CHECKSUM_STAGING}"
else
  echo "error: shasum or sha256sum is required to fingerprint the rootfs" >&2
  exit 1
fi
mv "${IMAGE_STAGING}" "${IMAGE}"
mv "${CHECKSUM_STAGING}" "${IMAGE}.sha256"

echo "Built root filesystem image:"
echo "  ${IMAGE}"
echo "  identity: ${IMAGE}.sha256"
echo "  size: ${SIZE_MIB} MiB"
echo "  staged: ${STAGED_MIB} MiB"
