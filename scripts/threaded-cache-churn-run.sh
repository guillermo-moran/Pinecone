#!/bin/sh
# Serial standalone test only; never touches baseline, guest, Simulator or Swift.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
baseline=${BASELINE_NATIVE:-/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative}
candidate_native=${CHURN_CANDIDATE_NATIVE:-$root/Sources/ARM64VizNative}
work=${CHURN_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/pinecone-threaded-cache-churn.XXXXXX")}
mode=${1:---check}
enabled=1
iterations=2000
flags='-O2'
case "$mode" in
    --check) ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --disabled) enabled=0 ;;
    --bench) iterations=${CHURN_ITERATIONS:-200000} ;;
    *) echo "usage: $0 [--check|--ubsan|--disabled|--bench]" >&2; exit 2 ;;
esac
mkdir -p "$work"
if [ -n "$(ls -A "$work")" ]; then
    echo "CHURN_OUTPUT must be empty: $work" >&2
    exit 2
fi
mkdir -p "$work/frozen" "$work/candidate-native"
cp -R "$baseline/." "$work/frozen/"
cp -R "$candidate_native/." "$work/candidate-native/"
cp "${CHURN_CANDIDATE_SOURCE:-$work/candidate-native/ARM64VizBlockCache.c}" "$work/candidate.c"
cp "${CHURN_HARNESS_SOURCE:-$root/scripts/threaded-cache-churn-harness.c}" "$work/harness.c"
cp "$0" "$work/runner.sh"
memory_aware=0
if grep -q 'avz_native_block_cache_threaded_program_with_memory(' "$work/candidate.c" &&
   grep -q 'avz_tp_supports_instruction_with_memory(' "$work/candidate-native/include/ARM64VizThreadedPrototype.h"; then
    memory_aware=1
fi
{
    printf 'mode=%s enabled=%s iterations=%s flags=%s baseline=%s candidate_native=%s memory_aware=%s\n' \
        "$mode" "$enabled" "$iterations" "$flags" "$baseline" "$candidate_native" "$memory_aware"
    printf 'comparison=frozen-baseline-dependencies versus candidate-snapshot-dependencies; not cache-policy-isolated\n'
    clang --version
    find "$work/frozen" -type f -exec shasum -a 256 {} \;
    find "$work/candidate-native" -type f -exec shasum -a 256 {} \;
    shasum -a 256 "$work/candidate.c" "$work/harness.c" "$work/runner.sh"
} > "$work/manifest.txt"
printf 'Evidence: %s\n' "$work"
exec > "$work/raw.txt" 2>&1
set -x
for dependency_set in frozen candidate-native; do
    mkdir "$work/objects-$dependency_set"
    for source in ARM64VizNative ARM64VizGuestMemory ARM64VizThreadedPrototype; do
        clang -std=c11 $flags -DAVZ_THREADED_PROTOTYPE_ENABLE=$enabled \
            -I "$work/$dependency_set/include" -I "$work/$dependency_set" \
            -c "$work/$dependency_set/$source.c" -o "$work/objects-$dependency_set/$source.o"
    done
done
for variant in baseline candidate candidate-quiet; do
    candidate=1; diagnostics=1; source="$work/candidate.c"
    dependencies="$work/candidate-native"; objects="$work/objects-candidate-native"
    variant_memory=$memory_aware
    if [ "$variant" = baseline ]; then
        candidate=0; source="$work/frozen/ARM64VizBlockCache.c"
        dependencies="$work/frozen"; objects="$work/objects-frozen"; variant_memory=0
    fi
    if [ "$variant" = candidate-quiet ]; then diagnostics=0; fi
    clang -std=c11 $flags -DAVZ_THREADED_PROTOTYPE_ENABLE=$enabled \
        -DAVZ_CHURN_CANDIDATE=$candidate -DAVZ_THREADED_CACHE_DIAGNOSTICS=$diagnostics \
        -DAVZ_CHURN_MEMORY_AWARE=$variant_memory \
        "-DAVZ_CACHE_SOURCE=\"$source\"" -I "$dependencies/include" -I "$dependencies" \
        "$work/harness.c" "$objects/ARM64VizNative.o" \
        "$objects/ARM64VizGuestMemory.o" \
        "$objects/ARM64VizThreadedPrototype.o" -lm -o "$work/$variant"
    shasum -a 256 "$work/$variant"
    "$work/$variant" "$iterations"
done
printf 'PASS evidence=%s\n' "$work"
