#!/usr/bin/env python3
"""Clone a LineageOS disk with an optional first-boot launcher provisioning service.

After Android reports sys.boot_completed=1, a one-shot service in the shipped
shell SELinux domain marks device/user setup complete. It reads both settings
back and only then disables Lineage SetupWizard's HOME component and requests
HOME. A settings failure therefore leaves SetupWizard enabled.

This is an emulator-test profile, not a general device provisioning mechanism.
Runtime behavior has not yet been boot-tested. It does not change SELinux
policy, remove the SetupWizard package, or modify the source image. Re-enable
the component with:

    pm enable --user 0 org.lineageos.setupwizard/.SetupWizardActivity
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
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists; refusing to overwrite")

    scripts = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "image_plan", scripts / "apply-lineageos-image-plan.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    debugfs = helper.find_tool(
        "DEBUGFS", ["/opt/homebrew/opt/e2fsprogs/sbin/debugfs", "debugfs"])
    fsck = helper.find_tool("E2FSCK", ["/opt/homebrew/opt/e2fsprogs/sbin/e2fsck", "e2fsck"])
    inspector = scripts / "inspect-lineageos-image.py"
    report = helper.inspect_image(inspector, args.source)
    partition = helper.partition_map(report)["system"]

    with tempfile.TemporaryDirectory(prefix="pinecone-launcher-provisioning-") as temp:
        work = Path(temp)
        image = helper.extract_partition(inspector, args.source, "system", work)
        target = "/system/etc/init/arm64viz-launcher-provisioning.rc"
        rc = work / "arm64viz-launcher-provisioning.rc"
        # `$$` escapes a literal `$` through Android init property expansion.
        command = (
            "settings put global device_provisioned 1 && "
            "settings --user 0 put secure user_setup_complete 1 && "
            "[ \\\"$$(settings get global device_provisioned)\\\" = 1 ] && "
            "[ \\\"$$(settings --user 0 get secure user_setup_complete)\\\" = 1 ] && "
            "pm disable-user --user 0 "
            "org.lineageos.setupwizard/.SetupWizardActivity && "
            "am start -a android.intent.action.MAIN "
            "-c android.intent.category.HOME")
        rc.write_text(
            "# Emulator-only, reversible SetupWizard completion.\n"
            "service arm64viz_launcher_provision /system/bin/sh -c \"{ "
            + command + "; } 2>&1 | log -t arm64viz-launcher-provision\"\n"
            "    class late_start\n"
            "    user shell\n"
            "    group shell log\n"
            "    seclabel u:r:shell:s0\n"
            "    disabled\n"
            "    oneshot\n\n"
            "on property:sys.boot_completed=1\n"
            "    start arm64viz_launcher_provision\n")
        action = {
            "path": target,
            "partition": "system",
            "replacementSha256": helper.sha256(rc),
            "selinuxContext": "u:object_r:system_file:s0",
        }
        helper.apply_action(action, rc, debugfs, image, work)
        helper.run([fsck, "-fn", str(image)])

        with tempfile.TemporaryDirectory(
                prefix=".pinecone-image-", dir=args.output.parent) as staging:
            staged = Path(staging) / "system.raw"
            helper.run(["cp", "-c", str(args.source), str(staged)])
            helper.write_partition(staged, report, partition, image)
            os.link(staged, args.output)
    print(
        f"Created {args.output}; source preserved. Runtime path is not yet boot-tested.")


if __name__ == "__main__":
    main()
