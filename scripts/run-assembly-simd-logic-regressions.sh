#!/bin/sh
set -eu
PINECONE_ASSEMBLY_FIXTURE=assembly-simd-logic-regression exec sh \
    "$(dirname "$0")/run-assembly-fp-moves-regressions.sh" "$@"
