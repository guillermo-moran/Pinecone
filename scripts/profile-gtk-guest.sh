#!/bin/sh
# Diagnostic only: launch from the guest console while Phosh is already running.
set -eu
case "${1:-}" in
  editor) app=/usr/bin/gnome-text-editor ;;
  settings) app=/usr/bin/gnome-control-center ;;
  *) echo 'usage: profile-gtk-guest.sh editor|settings NEW-OUTPUT-DIRECTORY' >&2; exit 2 ;;
esac
out=${2:?output directory required}
case "$out" in /*) ;; *) exit 2 ;; esac
if busybox pidof "${app##*/}" >/dev/null; then
  echo 'close the existing application before a cold-launch profile' >&2
  exit 1
fi
umask 077
mkdir "$out"
phosh=$(busybox pidof phosh)
case "$phosh" in ''|*' '*) echo 'exactly one Phosh session required' >&2; exit 1 ;; esac
busybox tr '\000' '\n' < "/proc/$phosh/environ" |
  busybox grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|GSK_RENDERER|GTK_A11Y|NO_AT_BRIDGE|PINECONE_WLROOTS_SHM_SNAPSHOT)=' > "$out/session-environment"
while IFS= read -r entry; do
  case "$entry" in
    WAYLAND_DISPLAY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*|GSK_RENDERER=*|GTK_A11Y=*|NO_AT_BRIDGE=*|PINECONE_WLROOTS_SHM_SNAPSHOT=*) export "$entry" ;;
  esac
done < "$out/session-environment"
rm "$out/session-environment"
export PINECONE_GTK_PRELOAD=/usr/lib/libpinecone-pixman.so:/usr/local/lib/libpinecone-gtk-latency.so
export PINECONE_GTK_LATENCY=1
if [ "${PINECONE_GTK_PROTOCOL_TRACE:-0}" = 1 ]; then
  export WAYLAND_DEBUG=client
else
  unset WAYLAND_DEBUG
fi
# Protocol logs may contain the deliberate test text. Keep artifacts private,
# do not use real documents/passwords, and close the app after the short sample.
LD_PRELOAD= exec /usr/local/bin/pinecone-profile-exec "$app" > "$out/app.log" 2>&1
