#!/usr/bin/env python3
"""Clone a LineageOS disk with focused, policy-compliant native stack samples.

The diagnostic starts when init reports SurfaceFlinger running, waits a
configurable interval, then asks debuggerd for focused app and compositor
backtraces. The app targets are SystemUI, Lineage SetupWizard, and Launcher3;
missing processes are reported and skipped. This trigger does not depend on a
successful Android framework boot. Output is sent through Android's log
service, which is already mirrored to the UART by the arm64viz boot profile. A
later SurfaceFlinger restart retriggers the disabled one-shot service after its
previous run has ended.

This uses the image's existing dumpstate SELinux domain. The copied shell is
labelled dumpstate_exec, causing the shipped init -> dumpstate transition;
the shipped policy explicitly permits dumpstate to execute shell/toolbox,
signal Android app domains, surfaceflinger, and system_server, and connect to
tombstoned and logd.
No policy, permissive mode, watchdog setting, or source image is changed.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import tempfile


KNOWN_TARGETS = (
    "com.android.systemui",
    "org.lineageos.setupwizard",
    "com.android.launcher3",
    "surfaceflinger",
    "system_server",
)
PRIORITY_TARGETS = ("system_server", "surfaceflinger")


def init_argument(value):
    """Quote one Android init service argument without changing shell syntax."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def selected_targets(explicit_targets):
    if explicit_targets is None:
        return list(KNOWN_TARGETS)
    explicit_targets = list(dict.fromkeys(explicit_targets))
    # debuggerd evidence from the framework and compositor is most useful
    # first if the caller requested either one explicitly.
    return (
        [target for target in PRIORITY_TARGETS if target in explicit_targets]
        + [target for target in explicit_targets if target not in PRIORITY_TARGETS]
    )


def capture_command(targets, delay_seconds, timeout_seconds, samples, interval_seconds):
    # Emit before the configurable delay so a boot can distinguish a working
    # init trigger/service launch from a delayed or failed debuggerd sample.
    commands = ["echo SERVICE_STARTED", f"sleep {delay_seconds}"]
    for sample in range(1, samples + 1):
        if sample > 1:
            commands.append(f"sleep {interval_seconds}")
        for target in targets:
            marker = f"SAMPLE_{sample}_PROCESS_{target}"
            commands.extend([
                f"echo BEGIN_{marker}",
                f"p=$$(pidof {target})",
                "p=$${p%% *}",
                (
                    "if [ -n \"$$p\" ]; then "
                    "echo ENVIRONMENT_RENDERER; "
                    "tr '\\000' '\\n' < /proc/$$p/environ | "
                    "grep -E '^(GALLIVM_PERF|GALLIUM_DRIVER)=' || true; "
                    "echo EXECUTABLE_MAPPINGS; "
                    "grep ' r.x' /proc/$$p/maps || true; "
                    f"timeout {timeout_seconds} debuggerd -b $$p; "
                    f"else echo PROCESS_ABSENT_{target}; fi"
                ),
                f"echo END_{marker}",
            ])
    return "{ " + "; ".join(commands) + "; } 2>&1 | log -t arm64viz-native-stack"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--delay-seconds", type=int, default=180)
    parser.add_argument("--per-process-timeout", type=int, default=20)
    parser.add_argument(
        "--target",
        action="append",
        choices=KNOWN_TARGETS,
        help="process to capture; repeat for multiple targets (default: all known targets)",
    )
    parser.add_argument("--samples", type=int, default=1)
    parser.add_argument("--sample-interval-seconds", type=int, default=20)
    args = parser.parse_args()
    if args.delay_seconds < 0 or args.delay_seconds > 3600:
        parser.error("--delay-seconds must be between 0 and 3600")
    if args.per_process_timeout < 1 or args.per_process_timeout > 60:
        parser.error("--per-process-timeout must be between 1 and 60")
    if args.samples < 1 or args.samples > 3:
        parser.error("--samples must be between 1 and 3")
    if args.sample_interval_seconds < 0 or args.sample_interval_seconds > 3600:
        parser.error("--sample-interval-seconds must be between 0 and 3600")
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

    with tempfile.TemporaryDirectory(prefix="pinecone-native-stacks-") as temp:
        work = Path(temp)
        image = helper.extract_partition(inspector, args.source, "system", work)

        diagnostic_shell = work / "arm64viz-dumpstate-sh"
        helper.run([debugfs, "-R", f"dump /system/bin/sh {diagnostic_shell}", str(image)])
        diagnostic_shell.chmod(0o755)
        rc = work / "arm64viz-native-stacks.rc"
        targets = selected_targets(args.target)
        command = capture_command(
            targets,
            args.delay_seconds,
            args.per_process_timeout,
            args.samples,
            args.sample_interval_seconds,
        )
        rc.write_text(
            "# One-shot focused native stacks; output tag is arm64viz-native-stack.\n"
            "service arm64viz_native_stacks /system/bin/arm64viz-dumpstate-sh -c "
            + init_argument(command) + "\n"
            "    class core\n"
            "    user root\n"
            "    group root log\n"
            "    disabled\n"
            "    oneshot\n\n"
            "on property:init.svc.surfaceflinger=running\n"
            "    start arm64viz_native_stacks\n")

        actions = [
            ({
                "path": "/system/bin/arm64viz-dumpstate-sh",
                "partition": "system",
                "replacementSha256": helper.sha256(diagnostic_shell),
                "selinuxContext": "u:object_r:dumpstate_exec:s0",
            }, diagnostic_shell),
            ({
                "path": "/system/etc/init/arm64viz-native-stacks.rc",
                "partition": "system",
                "replacementSha256": helper.sha256(rc),
                "selinuxContext": "u:object_r:system_file:s0",
            }, rc),
        ]
        for action, replacement in actions:
            helper.apply_action(action, replacement, debugfs, image, work)
        helper.run([fsck, "-fn", str(image)])

        with tempfile.TemporaryDirectory(
                prefix=".pinecone-image-", dir=args.output.parent) as staging:
            staged = Path(staging) / "system.raw"
            helper.run(["cp", "-c", str(args.source), str(staged)])
            helper.write_partition(staged, report, partition, image)
            os.link(staged, args.output)
    print(
        f"Created {args.output}; source preserved; delay={args.delay_seconds}s; "
        f"timeout={args.per_process_timeout}s; samples={args.samples}; "
        f"sample_interval={args.sample_interval_seconds}s; targets={','.join(targets)}")


if __name__ == "__main__":
    main()
