#!/usr/bin/env python3
"""Test the launch protocol without building the guest/app or using a display.

Usage: python3 scripts/run-application-policy-regressions.py phosh-0.57.0.tar.xz
       [--alpine-patch splash-timeout-flatpak-dbus.patch] [--swift] [--sanitizers]
Requires a C compiler, patch, pkg-config and gio-unix-2.0. Inputs stay offline.
On macOS, DesktopAppInfo metadata is shimmed; GIO signal emission remains real.
The real desktop spawn case runs only where DesktopAppInfo is available.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


HARNESS = r'''
#include <gio/gdesktopappinfo.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
static int writes, short_write;
static int control_open(const char *path, int flags) {
  g_assert_cmpstr(path, ==, "/dev/ttyAMA0");
  g_assert_true((flags & O_NONBLOCK) != 0);
  return 23;
}
static ssize_t control_write(int fd, const void *data, size_t size) {
  g_assert_cmpint(fd, ==, 23);
  g_assert_cmpuint(size, <, 2048);
  writes++;
  if (short_write == 2) { errno = EAGAIN; return -1; }
  size_t count = short_write ? 5 : size;
  fwrite(data, 1, count, stdout);
  return count;
}
#define open control_open
#define write control_write
#include "pinecone-launch-lifecycle.h"
#undef open
#undef write
static GAppInfo *info;
static GAppLaunchContext *begin(void) {
  GAppLaunchContext *context = g_app_launch_context_new();
  pinecone_launch_begin(context, info);
  return context;
}
static void signal_info(GAppLaunchContext *context, const char *signal, const char *id) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
  if (id) g_variant_builder_add(&builder, "{sv}", "startup-notification-id", g_variant_new_string(id));
  GVariant *data = g_variant_ref_sink(g_variant_builder_end(&builder));
  g_signal_emit_by_name(context, signal, info, data);
  g_variant_unref(data);
}
int main(int argc, char **argv) {
  setbuf(stdout, NULL);
  g_assert_cmpint(argc, ==, 3);
  info = G_APP_INFO(g_desktop_app_info_new_from_filename(argv[1]));
  g_assert_nonnull(info);
  g_assert_null(g_getenv("PINECONE_INTERACTION_TRACE"));
  puts("CASE duplicate");
  GAppLaunchContext *context = begin();
  pinecone_launch_begin(context, info);
  signal_info(context, "launch-started", "start-a");
  signal_info(context, "launch-started", "start-a");
  signal_info(context, "launched", "start-a");
  signal_info(context, "launched", "start-a");
  g_signal_emit_by_name(context, "launch-failed", "start-a");
  g_signal_emit_by_name(context, "launch-failed", "start-a");
  g_object_unref(context);

  puts("CASE multi");
  context = begin();
  signal_info(context, "launch-started", "old");
  signal_info(context, "launch-started", "new");
  signal_info(context, "launched", "new");
  g_signal_emit_by_name(context, "launch-failed", "old");
  g_signal_emit_by_name(context, "launch-failed", "old");
  signal_info(context, "launched", "new");
  g_object_unref(context);

  puts("CASE null-platform");
  context = begin();
  g_signal_emit_by_name(context, "launch-started", info, NULL);
  g_signal_emit_by_name(context, "launch-started", info, NULL);
  g_signal_emit_by_name(context, "launched", info, NULL);
  g_signal_emit_by_name(context, "launched", info, NULL);
  g_signal_emit_by_name(context, "launch-started", info, NULL);
  g_signal_emit_by_name(context, "launch-failed", NULL);
  g_object_unref(context);

  puts("CASE cancelled");
  context = begin();
  g_object_unref(context);
  puts("CASE sync-failure");
  context = begin();
  pinecone_launch_result(context, FALSE);
  pinecone_launch_result(context, FALSE);
  g_object_unref(context);

  puts("CASE existing-window");
  pinecone_launch_activate(info, "actual-wayland-ID");

#ifndef PINECONE_TEST_DESKTOP_SHIM
  puts("CASE real-spawn");
  context = begin();
  GError *error = NULL;
  gboolean success = g_app_info_launch(info, NULL, context, &error);
  g_assert_no_error(error);
  g_assert_true(success);
  pinecone_launch_result(context, success);
  g_object_unref(context);
#endif

  puts("CASE bounded");
  context = begin();
  for (int i = 0; i < 100; i++) {
    char id[24];
    snprintf(id, sizeof id, "start-%d", i);
    signal_info(context, "launch-started", id);
  }
  PineconeLaunchContext *state = g_object_get_data(G_OBJECT(context), "pinecone-launch");
  g_assert_cmpuint(state->count, ==, 16);
  g_object_unref(context);

  puts("CASE malformed-id");
  GAppInfo *bad = G_APP_INFO(g_desktop_app_info_new_from_filename(argv[2]));
  g_assert_nonnull(bad);
  pinecone_launch_activate(bad, "bad\"id");
  g_object_unref(bad);

  puts("CASE partial-write");
  short_write = 1;
  int before = writes;
  context = begin();
  g_assert_cmpint(writes - before, ==, 1);
  short_write = 0;
  g_object_unref(context);

  puts("CASE eagain");
  short_write = 2;
  before = writes;
  context = begin();
  g_assert_cmpint(writes - before, ==, 1);
  short_write = 0;
  g_object_unref(context);
  g_object_unref(info);
  return 0;
}
'''

# macOS GLib ships GOSXAppInfo, not Linux's DesktopAppInfo. This narrow fixture
# implements GAppInfo's ID and desktop-key reads, never the signal machinery.
DESKTOP_SHIM = r'''
#pragma once
#define PINECONE_TEST_DESKTOP_SHIM 1
#include <gio/gio.h>
typedef struct { GObject parent; GKeyFile *keys; char *id; char *wm_class; } FixtureDesktop;
typedef struct { GObjectClass parent; } FixtureDesktopClass;
static void fixture_desktop_iface_init(GAppInfoIface *iface);
G_DEFINE_TYPE_WITH_CODE(FixtureDesktop, fixture_desktop, G_TYPE_OBJECT,
                       G_IMPLEMENT_INTERFACE(G_TYPE_APP_INFO, fixture_desktop_iface_init))
static const char *fixture_id(GAppInfo *info) { return ((FixtureDesktop *)info)->id; }
static void fixture_desktop_iface_init(GAppInfoIface *iface) { iface->get_id = fixture_id; }
static void fixture_finalize(GObject *object) {
  FixtureDesktop *self = (FixtureDesktop *)object;
  g_clear_pointer(&self->keys, g_key_file_unref);
  g_free(self->id);
  g_free(self->wm_class);
  G_OBJECT_CLASS(fixture_desktop_parent_class)->finalize(object);
}
static void fixture_desktop_init(FixtureDesktop *self) { (void)self; }
static void fixture_desktop_class_init(FixtureDesktopClass *klass) {
  G_OBJECT_CLASS(klass)->finalize = fixture_finalize;
}
typedef FixtureDesktop GDesktopAppInfo;
#define G_DESKTOP_APP_INFO(object) ((GDesktopAppInfo *)(object))
#define G_IS_DESKTOP_APP_INFO(object) (G_TYPE_CHECK_INSTANCE_TYPE((object), fixture_desktop_get_type()))
static GDesktopAppInfo *g_desktop_app_info_new_from_filename(const char *filename) {
  FixtureDesktop *self = g_object_new(fixture_desktop_get_type(), NULL);
  self->keys = g_key_file_new();
  g_assert_true(g_key_file_load_from_file(self->keys, filename, G_KEY_FILE_NONE, NULL));
  self->id = g_path_get_basename(filename);
  self->wm_class = g_key_file_get_string(self->keys, "Desktop Entry", "StartupWMClass", NULL);
  return self;
}
static const char *g_desktop_app_info_get_startup_wm_class(GDesktopAppInfo *info) {
  return info->wm_class;
}
static char **g_desktop_app_info_get_string_list(GDesktopAppInfo *info, const char *key, gsize *length) {
  return g_key_file_get_string_list(info->keys, "Desktop Entry", key, length, NULL);
}
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--alpine-patch", type=Path)
    parser.add_argument("--swift", action="store_true")
    parser.add_argument("--sanitizers", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    expected = "51219a3295b061047765368a0f65a02b131c4b229ec03713f547595b73a98c51b99086769bf0584dd7d44b8426b21d50162e76e955fb7a37a5136cefa253fea8"
    assert hashlib.sha512(args.source.read_bytes()).hexdigest() == expected, "Unexpected phosh tarball"
    with tempfile.TemporaryDirectory(prefix="pinecone-application-policy-") as directory:
        work = Path(directory)
        run(["tar", "-xJf", str(args.source.resolve()), "-C", str(work)])
        source = work / "phosh-0.57.0"
        patches = [args.alpine_patch.resolve()] if args.alpine_patch else []
        patches += [root / f"scripts/patches/phosh-pinecone-{name}.patch" for name in
                    ["startup", "app-manifest", "service-profile", "launch-lifecycle"]]
        for patch in patches:
            run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)], cwd=source)
        tracker = (source / "src/app-tracker.c").read_text()
        grid = (source / "src/app-grid-button.c").read_text()
        assert 'pinecone_launch_activate (info, window_id);' in tracker
        assert 'pinecone_launch_begin (G_APP_LAUNCH_CONTEXT (context), info);' in tracker
        assert 'pinecone_launch_result (G_APP_LAUNCH_CONTEXT (context), success);' in tracker
        assert 'pinecone_launch_begin (G_APP_LAUNCH_CONTEXT (context), priv->info);' in grid
        assert 'g_object_unref (context)' not in tracker
        assert 'g_object_ref (context)' not in tracker
        (work / "regression.c").write_text(HARNESS)
        desktop = work / "org.example.Editor.desktop"
        desktop.write_text("[Desktop Entry]\nType=Application\nName=Test\nExec=/usr/bin/true\n"
                           "StartupNotify=false\nStartupWMClass=editor-window\n"
                           'X-Pinecone-WaylandAppIds=org.example.Wayland;bad/id;bad id;bad"id;editor-window;\n')
        malicious = work / 'bad"name.desktop'
        shutil.copyfile(desktop, malicious)
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "gio-unix-2.0"], text=True))
        shim = not any((Path(flag[2:]) / "gio/gdesktopappinfo.h").is_file()
                       for flag in flags if flag.startswith("-I"))
        if shim:
            (work / "shim/gio").mkdir(parents=True)
            (work / "shim/gio/gdesktopappinfo.h").write_text(DESKTOP_SHIM)
            flags = ["-I", str(work / "shim")] + flags
        sdk = []
        if sys.platform == "darwin":
            sdk = ["-isysroot", subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()]
        compiler = shlex.split(os.environ.get("CC", "cc"))
        sanitizers = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if args.sanitizers else []
        run(compiler + ["-std=gnu11", "-g", "-Wall", "-Wextra", "-Werror", *sdk,
                        *sanitizers,
                        "-I", str(source / "src"), str(work / "regression.c"), *flags,
                        "-o", str(work / "regression")])
        env = {k: v for k, v in os.environ.items() if k != "PINECONE_INTERACTION_TRACE"}
        env["G_DEBUG"] = "fatal-warnings"
        result = run([str(work / "regression"), str(desktop), str(malicious)],
                     text=True, capture_output=True, env=env, timeout=30)
        cases = {}
        for section in result.stdout.split("CASE ")[1:]:
            name, payload = section.split("\n", 1)
            records = []
            for record in payload.split("\x1ePINECONE_APP_LIFECYCLE ")[1:]:
                try:
                    records.append(json.loads(record.split("\n", 1)[0]))
                except json.JSONDecodeError:
                    pass  # Deliberately short UART write; next RS recovers.
            cases[name] = records
        expected_phases = {
            "duplicate": ["requested", "launched", "failed"],
            "multi": ["requested", "requested", "launched", "failed"],
            "null-platform": ["requested", "launched", "requested", "failed"],
            "cancelled": ["requested", "cancelled"],
            "sync-failure": ["requested", "failed"],
            "existing-window": ["requested", "launched"],
            "real-spawn": ["requested", "launched"],
            "bounded": ["requested"] * 16 + ["cancelled"] * 16,
            "malformed-id": [], "partial-write": ["cancelled"], "eagain": ["cancelled"],
        }
        if shim:
            del expected_phases["real-spawn"]
        assert set(cases) == set(expected_phases)
        for name, phases in expected_phases.items():
            records = cases[name]
            assert [r["event"] for r in records] == phases, (name, records)
            for record in records:
                assert record["version"] == 1
                assert record["desktopID"] == desktop.name
                aliases = ["org.example.Editor", "editor-window", "org.example.Wayland"]
                if name == "existing-window":
                    aliases.insert(0, "actual-wayland-ID")
                assert record["appIDs"] == aliases, record
        multi = cases["multi"]
        assert multi[0]["token"] == multi[3]["token"] != multi[1]["token"]
        assert multi[1]["token"] == multi[2]["token"]
        requested = [r["token"] for records in cases.values() for r in records if r["event"] == "requested"]
        assert len(requested) == len(set(requested))
        print(f"PASS: {len(cases)} C lifecycle scenarios, tracing disabled, patch stack fuzz=0")
        if args.sanitizers:
            print("ASan/UBSan enabled")
        if shim:
            print("LIMITATION: DesktopAppInfo metadata shim; real GIO signals tested, desktop spawn not run")
        if args.swift:
            package = work / "swift"
            sources = package / "Sources/ARM64VizCore"
            tests = package / "Tests/ARM64VizCoreTests"
            sources.mkdir(parents=True)
            tests.mkdir(parents=True)
            (package / "Package.swift").write_text('// swift-tools-version: 5.9\nimport PackageDescription\n'
                'let package = Package(name: "ApplicationPolicyRegression", targets: ['
                '.target(name: "ARM64VizCore"), .testTarget(name: "ARM64VizCoreTests", '
                'dependencies: ["ARM64VizCore"])])\n')
            for name in ["ApplicationExecutionPolicy", "GuestGraphicsTrace", "GuestControlConsoleFilter", "InteractionExecutionPolicy"]:
                shutil.copyfile(root / f"Sources/ARM64VizCore/{name}.swift", sources / f"{name}.swift")
            for name in ["ApplicationExecutionPolicyTests", "InteractionExecutionPolicyTests"]:
                shutil.copyfile(root / f"Tests/ARM64VizCoreTests/{name}.swift", tests / f"{name}.swift")
            swift_env = {**os.environ, "CLANG_MODULE_CACHE_PATH": str(work / "module-cache"),
                         "SWIFTPM_MODULECACHE_OVERRIDE": str(work / "module-cache")}
            run(["swift", "test", "--disable-sandbox", "--scratch-path", str(work / "swift-build"),
                 "--cache-path", str(work / "swift-cache"), "--config-path", str(work / "swift-config"),
                 "--security-path", str(work / "swift-security")],
                cwd=package, env=swift_env, timeout=180)


if __name__ == "__main__":
    main()
