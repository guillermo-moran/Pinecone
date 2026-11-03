#!/usr/bin/env python3
"""Make embedded graphics libraries use application framework runpaths.

Upstream Apple builds use bare framework names, which depend on the launching
process's DYLD_FRAMEWORK_PATH. App-local @rpath names also work in Simulator.
The changes are idempotent and confined to ignored dependency checkouts.
"""
from pathlib import Path
import sys

sources = Path(sys.argv[1])
angle = sources / "WebKit/Source/ThirdParty/ANGLE/src/common/system_utils.cpp"
text = angle.read_text()
old = 'std::string frameworkPath = std::string(libraryName) + ".framework/'
new = 'std::string frameworkPath = "@rpath/" + std::string(libraryName) + ".framework/'
if old not in text and new not in text:
    raise SystemExit("Unexpected ANGLE loader source; review the pinned dependency")
angle.write_text(text.replace(old, new))
epoxy = sources / "libepoxy/src/dispatch_common.c"
text = epoxy.read_text()
for name in ("EGL", "GLESv1_CM", "GLESv2"):
    text = text.replace(f'"{name}.framework/', f'"@rpath/{name}.framework/')
epoxy.write_text(text)
virgl = sources / "virglrenderer/src/virglrenderer.c"
text = virgl.read_text()
old = "if (!state.proxy_initialized) {"
new = "if (!state.proxy_initialized && (flags & VIRGL_RENDERER_VENUS)) {"
if old not in text and new not in text:
    raise SystemExit("Unexpected VirGL proxy initialization; review the pinned dependency")
# The Apple fork otherwise starts its Vulkan proxy even for a GLES-only
# embedder. No Vulkan capsets or server are built/advertised by Pinecone.
virgl.write_text(text.replace(old, new))
