#!/usr/bin/env python3
"""Clone an Android disk with Pinecone's precise GPU sysfs SELinux label.

Existing GPU permissions are reused; no allow rule or permissive domain is
added. The ODM precompiled policy is removed only from the clone so Android's
own secilc compiles the changed CIL inputs on boot. Source/userdata are untouched.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import tempfile

GPU_PATH = "/devices/platform/soc/30000000.pcie/pci0000:00/0000:00:05.0"
RULE = f'(genfscon sysfs "{GPU_PATH}" (u object_r sysfs_gpu ((s0) (s0))))'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.source.resolve() == args.output.resolve():
        parser.error("output must be a new path; source is never modified")
    scripts = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("image_plan", scripts / "apply-lineageos-image-plan.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    inspector = scripts / "inspect-lineageos-image.py"
    report = helper.inspect_image(inspector, args.source)
    partitions = helper.partition_map(report)
    debugfs = helper.find_tool("DEBUGFS", ["/opt/homebrew/opt/e2fsprogs/sbin/debugfs", "debugfs"])
    fsck = helper.find_tool("E2FSCK", ["/opt/homebrew/opt/e2fsprogs/sbin/e2fsck", "e2fsck"])
    with tempfile.TemporaryDirectory(prefix="pinecone-gpu-policy-") as temporary:
        work = Path(temporary)
        vendor_dir, odm_dir = work / "vendor", work / "odm"
        vendor_dir.mkdir(); odm_dir.mkdir()
        vendor = helper.extract_partition(inspector, args.source, "vendor", vendor_dir)
        odm = helper.extract_partition(inspector, args.source, "odm", odm_dir)
        original = work / "vendor-policy.original"
        path = "/etc/selinux/vendor_sepolicy.cil"
        helper.run([debugfs, "-R", f"dump {path} {original}", str(vendor)])
        contents = original.read_text()
        if GPU_PATH in contents:
            raise helper.PlanError("Pinecone GPU path already has policy; refusing duplicate rules")
        if '(genfscon sysfs ' not in contents or 'sysfs_gpu' not in contents:
            raise helper.PlanError("unexpected vendor policy: existing GPU labeling is missing")
        replacement = work / "vendor-policy.cil"
        replacement.write_text(contents.rstrip() + "\n; Pinecone virtio GPU discovery, using existing GPU permissions.\n" + RULE + "\n")
        helper.apply_action({"path": path, "replacementSha256": helper.sha256(replacement),
                             "selinuxContext": "u:object_r:vendor_configs_file:s0"},
                            replacement, debugfs, vendor, work)
        helper.run([debugfs, "-w", "-R", "rm /etc/selinux/precompiled_sepolicy", str(odm)])
        helper.run([fsck, "-fn", str(vendor)])
        helper.run([fsck, "-fn", str(odm)])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".pinecone-policy-", dir=args.output.parent) as staging:
            staged = Path(staging) / "system.raw"
            helper.run(["cp", "-c", str(args.source), str(staged)])
            helper.write_partition(staged, report, partitions["vendor"], vendor)
            helper.write_partition(staged, report, partitions["odm"], odm)
            os.link(staged, args.output)
    print(f"Created {args.output}; source preserved; GPU sysfs uses sysfs_gpu; SELinux remains enforcing")


if __name__ == "__main__":
    main()
