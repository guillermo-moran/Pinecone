#!/bin/sh
# Builds only graphics libraries. No emulator runtime or Android ROM is built.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
platform=${1:-iphonesimulator}
case "$platform" in
    iphonesimulator) target=arm64-apple-ios17.0-simulator; minimum=IPHONEOS_DEPLOYMENT_TARGET=17.0 ;;
    iphoneos) target=arm64-apple-ios17.0; minimum=IPHONEOS_DEPLOYMENT_TARGET=17.0 ;;
    macosx) target=arm64-apple-macos13.0; minimum=MACOSX_DEPLOYMENT_TARGET=13.0 ;;
    *) echo 'platform must be iphonesimulator, iphoneos or macosx' >&2; exit 2 ;;
esac
base="$root/.build/graphics"
sources="$base/sources"
prefix="$base/installed/$platform"
tools="$base/tools/bin"
mkdir -p "$sources" "$prefix/include" "$prefix/lib" "$base/work/$platform"
if test ! -x "$tools/meson"; then
    python3 -m venv "$base/tools"
    "$tools/pip" install meson==1.8.5 ninja==1.13.0 PyYAML==6.0.3
fi
"$tools/python3" -c 'import yaml' 2>/dev/null || "$tools/pip" install PyYAML==6.0.3
fetch() {
    name=$1 repository=$2 revision=$3
    if test ! -d "$sources/$name/.git"; then
        git clone --depth 1 --filter=blob:none --sparse "$repository" "$sources/$name"
    fi
    git -C "$sources/$name" fetch --depth 1 --filter=blob:none origin "$revision"
    if test "$name" = WebKit; then
        git -C "$sources/$name" sparse-checkout set Source/ThirdParty/ANGLE Configurations Tools/ccache
    else
        git -C "$sources/$name" sparse-checkout disable
    fi
    git -C "$sources/$name" checkout --detach "$revision"
}
fetch WebKit https://github.com/utmapp/WebKit.git ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10
fetch libepoxy https://github.com/utmapp/libepoxy.git bf98587477fe68d07b93319ece7b40a7d0e2eabe
fetch virglrenderer https://github.com/utmapp/virglrenderer.git 71a67414013f120c158729da7f56f29b55bf4f6c
python3 "$root/scripts/graphics/patch-loader-paths.py" "$sources"
angle="$sources/WebKit/Source/ThirdParty/ANGLE"
xcodebuild -project "$angle/ANGLE.xcodeproj" -scheme ANGLE -configuration Release \
    -sdk "$platform" -arch arm64 -derivedDataPath "$base/angle-$platform" \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO "$minimum" \
    ANGLE_ALLOWABLE_CLIENTS= WK_LIBCPP_ASSERTIONS_CFLAGS= build
case "$platform" in
    macosx) configuration=Release ;;
    *) configuration=Release-$platform ;;
esac
cp "$base/angle-$platform/Build/Products/$configuration/libEGL.dylib" "$prefix/lib/"
cp "$base/angle-$platform/Build/Products/$configuration/libGLESv2.dylib" "$prefix/lib/"
cp -R "$angle/include/." "$prefix/include/"
sdk=$(xcrun --sdk "$platform" --show-sdk-path)
cross="$base/work/$platform/cross.ini"
cat > "$cross" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$platform', 'clang']
objc = ['xcrun', '--sdk', '$platform', 'clang']
ar = ['xcrun', '--sdk', '$platform', 'ar']
strip = ['xcrun', '--sdk', '$platform', 'strip']
pkg-config = '/opt/homebrew/bin/pkg-config'
[built-in options]
c_args = ['-target', '$target', '-isysroot', '$sdk', '-I$prefix/include']
c_link_args = ['-target', '$target', '-isysroot', '$sdk', '-lobjc', '-framework', 'Foundation']
objc_args = ['-target', '$target', '-isysroot', '$sdk', '-I$prefix/include']
objc_link_args = ['-target', '$target', '-isysroot', '$sdk', '-lobjc', '-framework', 'Foundation']
default_library = 'shared'
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
export PATH="$tools:$PATH"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH=
meson setup --wipe "$base/work/$platform/epoxy" "$sources/libepoxy" \
    --cross-file "$cross" --prefix="$prefix" --buildtype=release \
    -Degl=yes -Dglx=no -Dx11=false -Dtests=false -Ddocs=false
ninja -C "$base/work/$platform/epoxy" install
meson setup --wipe "$base/work/$platform/virgl" "$sources/virglrenderer" \
    --cross-file "$cross" --prefix="$prefix" --buildtype=release \
    -Dplatforms=egl -Dvenus=false -Dvideo=false -Dtests=false -Ddrm-renderers=[]
ninja -C "$base/work/$platform/virgl" install
python3 "$root/scripts/graphics/package-frameworks.py" "$prefix" "$base/runtime/$platform" "$platform"
printf 'WebKit ANGLE ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10\nlibepoxy bf98587477fe68d07b93319ece7b40a7d0e2eabe\nvirglrenderer 71a67414013f120c158729da7f56f29b55bf4f6c\n' > "$base/runtime/$platform/REVISIONS"
printf 'Pinecone patches: app-local framework runpaths; GLES-only Vulkan-proxy gating\n' >> "$base/runtime/$platform/REVISIONS"
