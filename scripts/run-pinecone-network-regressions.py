#!/usr/bin/env python3
"""Host-only ownership tests. No real networking, guest, Lima, or simulator."""
import configparser
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parent
HELPER = SCRIPTS / "rootfs/pinecone-network"
INSTALLER = SCRIPTS / "rootfs/pinecone-network-install"

MOCK = r'''
import fcntl, json, os, pathlib, signal, sys, time
root = pathlib.Path(os.environ["PINECONE_NETWORK_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls").open("a") as log:
    log.write(json.dumps([name] + args) + "\n")
if name == "busybox":
    op, *args = args
    if op == "mkdir":
        os.execv("/bin/mkdir", ["mkdir"] + args)
    if op == "tr":
        os.execv("/usr/bin/tr", ["tr"] + args)
    if op == "flock":
        fd = int(args[-1])
        mode = fcntl.LOCK_UN if "-u" in args else fcntl.LOCK_EX | fcntl.LOCK_NB
        try: fcntl.flock(fd, mode)
        except BlockingIOError: sys.exit(1)
    elif op == "sleep":
        if os.environ.get("ADD_NIC"):
            (root / "sys/class/net/eth0").mkdir(exist_ok=True)
        time.sleep(0.02)
    elif op == "setsid":
        # Delayed bootstrap is tested directly, not leaked into the test host.
        pass
    elif op in ("ifconfig", "ip"):
        if os.environ.get("FAIL_STATIC") == op: sys.exit(1)
    elif op == "chown":
        assert args[0] in ("0:0", "0:101")
        if os.environ.get("FAIL_CHOWN"): sys.exit(1)
    elif op == "chmod":
        assert args[0] in ("0600", "4750")
        os.chmod(args[1], int(args[0], 8))
    else:
        raise AssertionError(op)
elif name == "udevadm":
    assert args == ["trigger", "--subsystem-match=net", "--action=add"]
elif name == "dbus-send":
    assert os.environ["DBUS_SYSTEM_BUS_ADDRESS"] == "unix:path=" + str(root / "run/dbus/system_bus_socket")
    if os.environ.get("FAIL_BUS"): sys.exit(1)
    if "org.freedesktop.NetworkManager.GetDeviceByIpIface" in args:
        print("/org/freedesktop/NetworkManager/Devices/2")
        sys.exit(0)
    if "org.freedesktop.DBus.Properties.GetAll" in args:
        assert "/org/freedesktop/NetworkManager/Devices/2" in args
        print('Managed: true; State: 100; Interface: eth0')
        sys.exit(0)
    if "org.freedesktop.DBus.StartServiceByName" in args:
        assert "--reply-timeout=120000" in args
        assert args[-2:] == ["string:org.freedesktop.NetworkManager", "uint32:0"]
        print("uint32 1")
        sys.exit(0)
    assert "--reply-timeout=2000" in args
    assert "org.freedesktop.DBus.NameHasOwner" in args
    print("boolean " + ("true" if (root / "nm-owner").exists() else "false"))
elif name == "NetworkManager":
    assert "--no-daemon" in args
    assert "LD_PRELOAD" not in os.environ
    try: os.fstat(9)
    except OSError: pass
    else: raise AssertionError("NM inherited ownership lock")
    (root / "nm-owner").touch()
    if os.environ.get("HOLD_NM"):
        while not (root / "release-nm").exists(): time.sleep(0.01)
    sys.exit(int(os.environ.get("NM_EXIT", "0")))
elif name == "nmcli":
    assert args[:2] == ["--wait", "3"] and args[-3:] == ["device", "show", "eth0"]
    print("GENERAL.STATE:100 (connected)\nGENERAL.CONNECTION:Pinecone Internet")
    sys.exit(int(os.environ.get("NMCLI_EXIT", "0")))
else:
    raise AssertionError(name)
'''


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinecone-network-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ("etc", "sys/class/net/eth0", "usr/bin", "usr/sbin", "run"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        for name in ("busybox", "usr/bin/dbus-send", "usr/bin/nmcli", "usr/sbin/NetworkManager"):
            script = self.root / name
            script.write_text(f"#!{sys.executable}\n" + MOCK)
            script.chmod(0o755)
        self.env = dict(os.environ, PINECONE_NETWORK_ROOT=str(self.root),
                        PINECONE_NETWORK_BUSYBOX=str(self.root / "busybox"))
        self.profile = self.root / "etc/NetworkManager/system-connections/pinecone-eth0.nmconnection"
        self.profile.parent.mkdir(parents=True)
        self.profile.write_text("mock installed profile\n")

    def run_helper(self, command, code=0, **env):
        result = subprocess.run(["/bin/sh", str(HELPER), command],
                                env=dict(self.env, **env), text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def calls(self, name=None):
        path = self.root / "calls"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in calls if name is None or call[0] == name]

    def writers(self):
        return [c for c in self.calls("busybox") if c[1] in ("ifconfig", "ip")]

    def test_start_coldplugs_network_before_activation(self):
        udev = self.root / "sbin/udevadm"
        udev.parent.mkdir()
        udev.write_text(f"#!{sys.executable}\n" + MOCK)
        udev.chmod(0o755)
        self.run_helper("start")
        self.assertEqual(self.calls()[0], ["udevadm", "trigger", "--subsystem-match=net", "--action=add"])
        self.assertEqual(self.calls()[1][0], "dbus-send")

    def test_status_uses_dbus_without_optional_cli(self):
        (self.root / "nm-owner").touch()
        (self.root / "usr/bin/nmcli").unlink()
        result = self.run_helper("status")
        self.assertIn("Managed: true", result.stdout)
        self.assertEqual(self.writers(), [])

    def test_activation_helper_is_secured_before_bus_activation(self):
        helper = self.root / "usr/libexec/dbus-daemon-launch-helper"
        helper.parent.mkdir(parents=True)
        helper.touch()
        self.run_helper("start")
        calls = self.calls()
        self.assertEqual(calls[0], ["busybox", "chown", "0:101", str(helper)])
        self.assertEqual(calls[1], ["busybox", "chmod", "4750", str(helper)])
        # The macOS sandbox can strip setuid from fixtures; assert the exact
        # chmod command above and verify effective guest mode in the VM smoke.
        self.assertEqual(stat.S_IMODE(helper.stat().st_mode) & 0o777, 0o750)
        self.assertEqual(calls[2][0], "dbus-send")

    def test_early_static_is_idempotent(self):
        self.run_helper("early")
        self.assertEqual(self.writers(), [
            ["busybox", "ifconfig", "lo", "127.0.0.1", "up"],
            ["busybox", "ifconfig", "eth0", "10.0.2.15", "netmask", "255.255.255.0", "up"],
            ["busybox", "ip", "route", "replace", "default", "via", "10.0.2.2", "dev", "eth0", "metric", "0"],
        ])
        resolver = self.root / "etc/resolv.conf"
        self.assertIn("nameserver 10.0.2.3", resolver.read_text())
        resolver.write_text("preserve later resolver settings\n")
        self.run_helper("early")
        self.assertEqual(len(self.writers()), 3)
        self.assertEqual(resolver.read_text(), "preserve later resolver settings\n")
        self.assertFalse(self.calls("dbus-send"))
        self.assertFalse(self.calls("NetworkManager"))
        self.assertFalse([c for c in self.calls("busybox") if c[1] == "sleep"])

    def test_missing_interface_does_not_delay_shell(self):
        (self.root / "sys/class/net/eth0").rmdir()
        self.run_helper("early")
        self.assertFalse([c for c in self.calls("busybox") if c[1] == "sleep"])
        # Wait only for the mocked detached dispatch to be recorded.
        self.wait_for(lambda: any(c[1] == "setsid" for c in self.calls("busybox")))
        self.assertEqual(len(self.writers()), 1)
        self.run_helper("late", ADD_NIC="1")
        self.assertTrue((self.root / "run/pinecone-network/static-ready").exists())

    def test_missing_interface_retry_is_bounded(self):
        (self.root / "sys/class/net/eth0").rmdir()
        self.run_helper("late", code=1)
        self.assertEqual(len([c for c in self.calls("busybox") if c[1] == "sleep"]), 5)

    def test_failed_static_can_retry(self):
        self.run_helper("early", code=1, FAIL_STATIC="ip")
        self.assertFalse((self.root / "run/pinecone-network/static-ready").exists())
        self.run_helper("early")
        self.assertTrue((self.root / "run/pinecone-network/static-ready").exists())

    def test_no_bus_preserves_static_and_allows_retry(self):
        self.run_helper("early")
        self.run_helper("daemon", code=1, FAIL_BUS="1")
        self.assertFalse(self.calls("NetworkManager"))
        self.assertFalse((self.root / "run/pinecone-network/nm-started").exists())
        self.run_helper("daemon")
        self.assertEqual(len(self.calls("NetworkManager")), 1)
        self.assertEqual(len(self.writers()), 3)

    def test_missing_nm_preserves_static(self):
        self.run_helper("early")
        (self.root / "usr/sbin/NetworkManager").unlink()
        self.run_helper("daemon", code=1)
        self.assertEqual(len(self.writers()), 3)

    def test_profile_is_secured_before_nm_starts(self):
        self.profile.chmod(0o644)
        self.run_helper("daemon")
        self.assertEqual(stat.S_IMODE(self.profile.stat().st_mode), 0o600)
        operations = [c[1] if c[0] == "busybox" else c[0] for c in self.calls()]
        self.assertLess(operations.index("chown"), operations.index("NetworkManager"))
        self.assertLess(operations.index("chmod"), operations.index("NetworkManager"))

    def test_missing_or_unsecurable_profile_preserves_static(self):
        self.run_helper("early")
        self.run_helper("daemon", code=1, FAIL_CHOWN="1")
        self.profile.unlink()
        self.run_helper("daemon", code=1)
        self.assertFalse(self.calls("NetworkManager"))
        self.assertFalse((self.root / "run/pinecone-network/nm-started").exists())
        self.assertEqual(len(self.writers()), 3)

    def test_nm_failure_never_replays_static(self):
        self.run_helper("daemon", code=7, NM_EXIT="7")
        self.assertEqual(len(self.writers()), 3)
        self.run_helper("early")
        self.run_helper("late")
        self.assertEqual(len(self.writers()), 3)
        (self.root / "nm-owner").unlink()
        self.run_helper("daemon")
        self.assertEqual(len(self.calls("NetworkManager")), 2)
        self.assertEqual(len(self.writers()), 3)

    def test_external_nm_owner_skips_bootstrap_and_duplicate_start(self):
        (self.root / "nm-owner").touch()
        self.run_helper("daemon")
        self.run_helper("early")
        self.assertFalse(self.calls("NetworkManager"))
        self.assertFalse(self.writers())

    def wait_for(self, predicate):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if predicate(): return
            time.sleep(0.01)
        self.fail("mock worker did not reach expected state")

    def test_concurrent_daemon_and_bootstrap_cannot_fight(self):
        with (self.root / "daemon.log").open("w") as log:
            process = subprocess.Popen(["/bin/sh", str(HELPER), "daemon"],
                                       env=dict(self.env, HOLD_NM="1"), stdout=log, stderr=log)
            try:
                self.wait_for(lambda: (self.root / "nm-owner").exists())
                before = self.writers()
                self.run_helper("daemon")
                self.run_helper("early")
                self.assertEqual(self.writers(), before)
                self.assertEqual(len(self.calls("NetworkManager")), 1)
            finally:
                (self.root / "release-nm").touch()
                process.wait(timeout=5)
        self.assertEqual(process.returncode, 0)

    def test_daemon_waits_for_inflight_static_writer(self):
        import fcntl
        state = self.root / "run/pinecone-network"
        state.mkdir()
        with (state / "owner.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with (self.root / "daemon.log").open("w") as log:
                process = subprocess.Popen(["/bin/sh", str(HELPER), "daemon"],
                                           env=self.env, stdout=log, stderr=log)
                try:
                    self.wait_for(lambda: any(c[1] == "sleep" for c in self.calls("busybox")))
                    self.assertFalse(self.calls("NetworkManager"))
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    process.wait(timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(len(self.calls("NetworkManager")), 1)

    def test_status_is_read_only_and_reports_failures(self):
        self.assertIn("system-dbus: unavailable", self.run_helper("status", code=1, FAIL_BUS="1").stdout)
        self.assertIn("networkmanager: unavailable", self.run_helper("status", code=1).stdout)
        (self.root / "nm-owner").touch()
        result = self.run_helper("status")
        self.assertIn("system-dbus: ready", result.stdout)
        self.assertIn("Pinecone Internet", result.stdout)
        self.run_helper("status", code=10, NMCLI_EXIT="10")
        self.assertFalse(self.writers())
        self.assertFalse(self.calls("NetworkManager"))

    def test_start_delegates_to_bus_without_mutating_network(self):
        self.run_helper("start")
        self.run_helper("start", code=1, FAIL_BUS="1")
        self.assertEqual(len(self.calls("dbus-send")), 2)
        self.assertFalse(self.calls("NetworkManager"))
        self.assertFalse(self.writers())
        self.assertFalse((self.root / "run/pinecone-network").exists())

    def test_installer_static_profile_permissions_and_activation(self):
        config = self.root / "etc/NetworkManager/conf.d/10-pinecone.conf"
        config.parent.mkdir(parents=True)
        config.write_text("[keyfile]\nunmanaged-devices=interface-name:eth0\n")
        for _ in range(2):
            subprocess.run(["/bin/sh", str(INSTALLER), str(self.root)], check=True)
        nm = configparser.ConfigParser()
        nm.read(config)
        self.assertEqual(nm["keyfile"]["unmanaged-devices"], "")
        self.assertEqual(nm["device-pinecone"]["keep-configuration"], "yes")
        self.assertEqual(nm["device-pinecone"]["managed"], "1")
        self.assertEqual(nm["main"]["rc-manager"], "file")
        profile_path = self.root / "etc/NetworkManager/system-connections/pinecone-eth0.nmconnection"
        self.assertEqual(stat.S_IMODE(profile_path.stat().st_mode), 0o600)
        profile = configparser.ConfigParser()
        profile.read(profile_path)
        self.assertEqual(profile["connection"]["interface-name"], "eth0")
        self.assertEqual(profile["ipv4"]["method"], "manual")
        self.assertEqual(profile["ipv4"]["address1"], "10.0.2.15/24")
        self.assertEqual(profile["ipv4"]["gateway"], "10.0.2.2")
        self.assertEqual(profile["ipv4"]["dns"], "10.0.2.3;")
        self.assertEqual(profile["ipv4"]["route-metric"], "0")
        self.assertEqual(profile["ipv6"]["method"], "ignore")
        activation = self.root / "usr/share/dbus-1/system-services/org.freedesktop.NetworkManager.service"
        self.assertIn("Exec=/usr/local/bin/pinecone-network daemon", activation.read_text())
        self.assertNotIn("SystemdService", activation.read_text())
        self.assertTrue(os.access(self.root / "usr/local/bin/pinecone-network", os.X_OK))

    def test_boot_and_session_wiring(self):
        init = (SCRIPTS / "rootfs/arm64viz-root-init").read_text()
        self.assertIn("/usr/local/bin/pinecone-network early", init)
        self.assertNotIn("ifconfig eth0", init)
        self.assertNotIn("/etc/resolv.conf", init)
        launcher = (SCRIPTS / "rootfs/pinecone-session-launcher.c").read_text()
        session = launcher.split("static int run_session(void)", 1)[1].split("static pid_t start_osk", 1)[0]
        self.assertLess(session.index("prepare_system_bus();"), session.index("start_network_manager();"))
        self.assertLess(session.index("start_network_manager();"), session.index("setpriority("))


if __name__ == "__main__":
    unittest.main(verbosity=2)
