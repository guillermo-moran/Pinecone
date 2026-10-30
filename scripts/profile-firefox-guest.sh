#!/bin/sh
# Opt-in guest diagnostics; deliberately not installed by the image builder.
set -eu

fail() { echo "firefox-profile: $*" >&2; exit 1; }
usage() {
  printf '%s\n' \
    'Usage: sh profile-firefox-guest.sh --capture /absolute/NEW-directory [URL ...]' \
    'Run only in the guest Phosh session, with Firefox fully closed.' \
    'No URL preserves the normal launcher default; use about:blank explicitly.' \
    'PINECONE_FIREFOX_PROFILE_MODE=main|graphics (default main)' \
    'PINECONE_FIREFOX_PROFILE_INTERVAL_MS=10|20|50 (default 10)' \
    'PINECONE_FIREFOX_PROFILE_ENTRIES=1048576|2097152|4194304 (default 1048576)' \
    'Buffer-bounded, NOT time-bounded. Quit Firefox normally to save shutdown.json.' \
    'No signals, preference edits, profile cleanup, remote debugging, or uploads.'
}

if [ "${1:-}" = --help ]; then usage; exit 0; fi
[ "$#" -ge 2 ] && [ "$1" = --capture ] || { usage >&2; exit 2; }
out=$2
shift 2
case "$out" in /*) ;; *) fail 'output directory must be absolute' ;; esac
# Gecko expands %p in shutdown paths; disallow ambiguity in artifact locations.
case "$out" in *%*) fail 'output directory must not contain %' ;; esac
for url do
  case "$url" in
    http://*|https://*|file://*|about:*) ;;
    *) fail "expected an HTTP(S), file, or about URL: $url" ;;
  esac
done

mode=${PINECONE_FIREFOX_PROFILE_MODE:-main}
case "$mode" in
  main) filters=GeckoMain ;;
  graphics) filters=GeckoMain,Compositor,Renderer,RenderBackend,SceneBuilder,SwComposite,Software ;;
  *) fail 'mode must be main or graphics' ;;
esac
interval=${PINECONE_FIREFOX_PROFILE_INTERVAL_MS:-10}
case "$interval" in 10|20|50) ;; *) fail 'interval must be 10, 20, or 50 ms' ;; esac
entries=${PINECONE_FIREFOX_PROFILE_ENTRIES:-1048576}
case "$entries" in 1048576|2097152|4194304) ;; *) fail 'entries must be 1048576, 2097152, or 4194304' ;; esac

# Refuse hidden feature-bitfield/retention overrides instead of silently changing them.
if env | grep -Eq '^(MOZ_PROFILER_|MOZ_BASE_PROFILER_|MOZ_LOG=|MOZ_LOG_FILE=)'; then
  fail 'remove inherited profiler/logging variables in this command environment first'
fi
if env | grep -Eq '^(MOZ_DISABLE_.*SANDBOX|MOZ_FORCE_DISABLE_E10S|MOZ_FORCE_DISABLE_FISSION)='; then
  fail 'refusing an environment with sandbox/process-isolation overrides'
fi
[ -r /proc/self/status ] || fail 'run inside the Linux guest, not on the host'
[ -n "${WAYLAND_DISPLAY:-}${WAYLAND_SOCKET:-}" ] || fail 'Phosh Wayland session is missing'
[ -n "${XDG_RUNTIME_DIR:-}" ] || fail 'XDG_RUNTIME_DIR is missing'
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || fail 'session D-Bus address is missing'
profile="${HOME:?HOME is required}/.mozilla/pinecone"
[ -s "$profile/user.js" ] || fail 'existing seeded Pinecone profile required; no first-run seeding here'
command -v firefox >/dev/null 2>&1 || fail 'Firefox is not installed'
command -v pinecone-launch-firefox >/dev/null 2>&1 || fail 'normal launcher is missing'

# This is a conservative remoting guard, not a replacement for Firefox's lock.
# The manager must prevent simultaneous launches during the check/launch gap.
for comm in /proc/[0-9]*/comm; do
  [ -r "$comm" ] || continue
  name=
  IFS= read -r name < "$comm" || continue
  case "$name" in firefox|firefox-bin) fail 'Firefox is already running; quit normally first' ;; esac
done

umask 077
mkdir "$out" || fail 'output directory must be new, with an existing trusted parent'
out=$(CDPATH= cd "$out" && pwd -P)
case "$out" in *%*) fail 'resolved output directory must not contain %' ;; esac
MOZ_PROFILER_HELP=1 firefox > "$out/profiler-help.txt" 2>&1 || fail 'profiler help failed'
for option in STARTUP STARTUP_ENTRIES STARTUP_INTERVAL STARTUP_FEATURES STARTUP_FILTERS SHUTDOWN; do
  grep -Eq "^[[:space:]]*MOZ_PROFILER_${option}([=<[:space:]]|$)" "$out/profiler-help.txt" ||
    fail "profiler option not confirmed: $option"
done
for feature in js stackwalk cpu; do
  grep -Eq "^[[:space:]]+[DS-][[:space:]]+[0-9]+: \"$feature\"" "$out/profiler-help.txt" ||
    fail "required profiler feature unavailable: $feature (see profiler-help.txt)"
done

export MOZ_PROFILER_STARTUP=1
export MOZ_PROFILER_STARTUP_ENTRIES="$entries"
export MOZ_PROFILER_STARTUP_INTERVAL="$interval"
export MOZ_PROFILER_STARTUP_FEATURES=js,stackwalk,cpu
export MOZ_PROFILER_STARTUP_FILTERS="$filters"
export MOZ_PROFILER_SHUTDOWN="$out/shutdown.json"
{
  printf 'mode=%s\nentries=%s\ninterval_ms=%s\nfeatures=%s\nfilters=%s\n' \
    "$mode" "$entries" "$interval" "$MOZ_PROFILER_STARTUP_FEATURES" "$filters"
  printf 'profile=%s\nshutdown=%s\n' "$profile" "$MOZ_PROFILER_SHUTDOWN"
  printf 'launch_utc='; date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf 'guest_uptime='; cat /proc/uptime
  if [ "$#" -eq 0 ]; then printf 'url=(normal launcher default)\n'; fi
  for url do printf 'url=%s\n' "$url"; done
} > "$out/run.txt"
echo "firefox-profile: recording to $out; manager must quit normally when done" >&2
status=0
pinecone-launch-firefox "$@" > "$out/firefox.log" 2>&1 || status=$?
{
  printf 'exit_status=%s\nexit_utc=' "$status"; date -u '+%Y-%m-%dT%H:%M:%SZ'
} >> "$out/run.txt"
[ "$status" -eq 0 ] || exit "$status"
[ -s "$out/shutdown.json" ] || fail 'no shutdown profile; preserve logs and check for a separately saved UI capture'
echo 'firefox-profile: nonempty shutdown file saved; validate JSON, time range, and process coverage on host' >&2
