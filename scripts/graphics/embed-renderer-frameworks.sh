#!/bin/sh
set -eu
test "${PINECONE_EMBED_VIRGL:-0}" = 1 || exit 0
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime="$root/.build/graphics/runtime/${PLATFORM_NAME:?}"
destination="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
mkdir -p "$destination"
for name in GLESv2 EGL epoxy.0 virglrenderer.1; do
    test -f "$runtime/$name.framework/$name" || {
        echo "Missing $runtime/$name.framework. Run scripts/graphics/build-renderer-dependencies.sh $PLATFORM_NAME" >&2
        exit 1
    }
    rsync -a --delete "$runtime/$name.framework/" "$destination/$name.framework/"
    if test "${CODE_SIGNING_ALLOWED:-NO}" = YES; then
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination/$name.framework"
    fi
done
notices="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GraphicsNotices"
mkdir -p "$notices"
cp "$runtime/REVISIONS" "$notices/"
cp "$root/.build/graphics/sources/WebKit/Source/ThirdParty/ANGLE/LICENSE" "$notices/ANGLE.txt"
cp "$root/.build/graphics/sources/libepoxy/COPYING" "$notices/libepoxy.txt"
cp "$root/.build/graphics/sources/virglrenderer/COPYING" "$notices/virglrenderer.txt"
