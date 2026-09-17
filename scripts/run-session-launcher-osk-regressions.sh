#!/usr/bin/env bash
set -euo pipefail
# Run from the repository root: bash scripts/run-session-launcher-osk-regressions.sh
# Mocked policy/error-path checks are mandatory. Only the real kernel check
# reports SKIP when setpriority is denied or unsupported; other errors fail.
# Run on an unrestricted host to verify priority across exec as well.
if [[ "${1:-}" == --help ]]; then
  printf '%s\n' \
    'Usage: bash scripts/run-session-launcher-osk-regressions.sh' \
    'Runs native host tests; no guest, simulator, or device operations.' \
    'Mocked policy/error-path checks always run.' \
    'Kernel priority/exec check explicitly SKIPs denied/unsupported setpriority.' \
    'A skip exits successfully; unexpected errors and regressions fail.' \
    'Use an unrestricted host to also verify kernel priority across exec.'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-osk-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
  "$ROOT/scripts/session-launcher-osk-regression.c" -o "$WORK/osk-regression"
"$WORK/osk-regression"
