#!/usr/bin/env python3
"""Wrap the four graphics dylibs as application-local Apple frameworks."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

prefix, output = map(pathlib.Path, sys.argv[1:3])
platform = sys.argv[3]
libraries = {"GLESv2": "libGLESv2.dylib", "EGL": "libEGL.dylib",
             "epoxy.0": "libepoxy.0.dylib", "virglrenderer.1": "libvirglrenderer.1.dylib"}
output.mkdir(parents=True, exist_ok=True)
for name, library in libraries.items():
    framework = output / f"{name}.framework"
    framework.mkdir(exist_ok=True)
    if platform == "macosx":
        version = framework / "Versions/A"
        (version / "Resources").mkdir(parents=True, exist_ok=True)
        for link, target in ((framework / "Versions/Current", "A"),
                             (framework / name, f"Versions/Current/{name}"),
                             (framework / "Resources", "Versions/Current/Resources")):
            if not link.exists():
                link.symlink_to(target)
        binary = version / name
        info = version / "Resources/Info.plist"
    else:
        binary = framework / name
        info = framework / "Info.plist"
    shutil.copyfile(prefix / "lib" / library, binary)
    binary.chmod(0o755)
    dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    subprocess.run(["install_name_tool", "-id", f"@rpath/{name}.framework/{name}", str(binary)], check=True)
    for line in dependencies:
        dependency = line.strip().split(" (", 1)[0]
        for target, filename in libraries.items():
            if pathlib.Path(dependency).name == filename:
                subprocess.run(["install_name_tool", "-change", dependency,
                                f"@rpath/{target}.framework/{target}", str(binary)], check=True)
    supported = {"iphonesimulator": "iPhoneSimulator", "iphoneos": "iPhoneOS", "macosx": "MacOSX"}[platform]
    metadata = dict(CFBundleExecutable=name, CFBundleIdentifier="me.gmoran.pinecone.graphics." + name.replace(".", "-"),
                    CFBundleName=name, CFBundlePackageType="FMWK", CFBundleVersion="1", CFBundleShortVersionString="1.0",
                    CFBundleSupportedPlatforms=[supported], MinimumOSVersion="13.0" if platform == "macosx" else "17.0")
    info.write_bytes(plistlib.dumps(metadata))
    subprocess.run(["codesign", "--force", "--sign", "-", str(framework)], check=True)
print(output)
