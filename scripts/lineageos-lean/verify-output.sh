#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 PRODUCT_OUT" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage
product_out=$(cd "$1" && pwd)
installed_roots=()
for root in system system_ext product vendor odm root recovery; do
  [[ -e "$product_out/$root" ]] && installed_roots+=("$product_out/$root")
done
[[ ${#installed_roots[@]} -gt 0 ]] || {
  echo "no installed Android partition trees under $product_out" >&2
  exit 1
}

require_file() {
  local relative=$1
  [[ -f "$product_out/$relative" ]] || {
    echo "missing required build output: $relative" >&2
    return 1
  }
}

require_named_file() {
  local name=$1
  find "${installed_roots[@]}" -type f -name "$name" -print -quit | grep -q . || {
    echo "missing required UI/runtime payload: $name" >&2
    return 1
  }
}

require_file boot.img
require_file vendor_boot.img
require_named_file surfaceflinger
require_named_file SystemUI.apk
require_named_file Settings.apk
require_named_file Launcher3QuickStepGo.apk
require_named_file Provision.apk

find "${installed_roots[@]}" -type f -path '*/apex/*' -print -quit | grep -q . || {
  echo "missing APEX payload" >&2
  exit 1
}

build_prop=$(grep -Rl '^ro.build.type=user$' "${installed_roots[@]}" --include=build.prop | head -1 || true)
[[ -n "$build_prop" ]] || {
  echo "no build.prop identifies this output as a user build" >&2
  exit 1
}

low_ram_prop=$(grep -Rl '^ro.config.low_ram=true$' "${installed_roots[@]}" --include=build.prop | head -1 || true)
[[ -n "$low_ram_prop" ]] || {
  echo "output is missing Android Go's ro.config.low_ram=true configuration" >&2
  exit 1
}

if find "${installed_roots[@]}" -type f \( -name '*SetupWizard*.apk' -o -name '*GmsCore*.apk' -o -name 'Phonesky.apk' \) -print -quit | grep -q .; then
  echo "AOSP Go output unexpectedly contains SetupWizard or Google services" >&2
  exit 1
fi

for excluded in setup_sound_card setup_wifi android.hardware.sensors-service.multihal; do
  if find "${installed_roots[@]}" -type f -name "$excluded" -print -quit | grep -q .; then
    echo "excluded optional service was installed: $excluded" >&2
    exit 1
  fi
done

echo "Verified AOSP Go configuration, user build, provisioner, UI, APEX, and lean-device exclusions"
