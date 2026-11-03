#!/usr/bin/env python3
"""Create a cloned LineageOS image without eager Mesa shader prewarming.

Rendering remains enabled; shaders are compiled on demand. Only the
selected Mesa boot profile is affected. The input image is never modified.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--graphics-profile", choices=("mesa_swrast", "mesa"), default="mesa_swrast")
    parser.add_argument(
        "--disable-llvm-optimizations",
        action="store_true",
        help=("set GALLIVM_PERF=nopt for mesa_swrast to reduce llvmpipe "
              "first-use shader compilation time"),
    )
    parser.add_argument(
        "--force-softpipe",
        action="store_true",
        help=("set GALLIUM_DRIVER=softpipe for mesa_swrast; this avoids the "
              "LLVM-based llvmpipe path; diagnostic only: the current image "
              "fails Android EGL-image import with this backend"),
    )
    args = parser.parse_args()
    if args.graphics_profile != "mesa_swrast" and (args.disable_llvm_optimizations or args.force_softpipe):
        parser.error("software renderer overrides require --graphics-profile mesa_swrast")
    if args.disable_llvm_optimizations and args.force_softpipe:
        parser.error(
            "--disable-llvm-optimizations and --force-softpipe are mutually exclusive")
    if args.output.exists():
        parser.error("output already exists; refusing to overwrite")
    scripts = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("image_plan", scripts / "apply-lineageos-image-plan.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    debugfs = helper.find_tool("DEBUGFS", ["/opt/homebrew/opt/e2fsprogs/sbin/debugfs", "debugfs"])
    fsck = helper.find_tool("E2FSCK", ["/opt/homebrew/opt/e2fsprogs/sbin/e2fsck", "e2fsck"])
    inspector = scripts / "inspect-lineageos-image.py"
    report = helper.inspect_image(inspector, args.source)
    partition = helper.partition_map(report)["system"]
    with tempfile.TemporaryDirectory(prefix="pinecone-software-rendering-") as temp:
        work = Path(temp)
        image = helper.extract_partition(inspector, args.source, "system", work)
        original = work / "surfaceflinger.rc.original"
        target = "/system/etc/init/surfaceflinger.rc"
        helper.run([debugfs, "-R", f"dump {target} {original}", str(image)])
        contents = original.read_text()
        if "service surfaceflinger /system/bin/surfaceflinger" not in contents:
            raise helper.PlanError("unexpected SurfaceFlinger service definition")
        trigger = f"on early-init && property:ro.boot.graphics={args.graphics_profile}"
        if trigger + "\n" in contents or ("service.sf.prime_shader_cache" in contents and
            (args.graphics_profile != "mesa" or "on early-init && property:ro.boot.graphics=mesa_swrast\n" not in contents)):
            raise helper.PlanError("shader prewarming is already configured; refusing to duplicate")
        action_lines = "    setprop service.sf.prime_shader_cache 0\n"
        if args.disable_llvm_optimizations:
            action_lines += (
                "    # Skip Gallivm optimization passes to bound first-use shader JIT time.\n"
                "    export GALLIVM_PERF nopt\n")
        if args.force_softpipe:
            action_lines += (
                "    # Select the non-LLVM Gallium software rasterizer.\n"
                "    export GALLIUM_DRIVER softpipe\n")
        replacement = work / "surfaceflinger.rc"
        replacement.write_text(contents.rstrip() + "\n\n"
            "# Compile required shaders on demand instead of\n"
            "# monopolizing RenderEngine with speculative startup prewarming.\n"
            + trigger + "\n"
            + action_lines)
        action = {
            "path": target,
            "partition": "system",
            "replacementSha256": helper.sha256(replacement),
            "selinuxContext": "u:object_r:system_file:s0",
        }
        helper.apply_action(action, replacement, debugfs, image, work)
        helper.run([fsck, "-fn", str(image)])
        # Stage beside the destination, then publish without overwriting even
        # if another caller creates the destination while we are preparing it.
        with tempfile.TemporaryDirectory(prefix=".pinecone-image-", dir=args.output.parent) as staging:
            staged = Path(staging) / "system.raw"
            helper.run(["cp", "-c", str(args.source), str(staged)])
            helper.write_partition(staged, report, partition, image)
            os.link(staged, args.output)
    rendering_override = ""
    if args.disable_llvm_optimizations:
        rendering_override = "; GALLIVM_PERF=nopt"
    elif args.force_softpipe:
        rendering_override = "; GALLIUM_DRIVER=softpipe (known Android EGL-image import failure)"
    print(
        f"Created {args.output}; source preserved{rendering_override}. "
        f"Boot with androidboot.graphics={args.graphics_profile}.")


if __name__ == "__main__":
    main()
