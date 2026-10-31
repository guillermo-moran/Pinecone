# Cold App Startup: Agent 4 Report

Date: 2026-10-31. Scope: startup-specific cache/rootfs integration.

## Outcome

Restored the missing GIO module-cache generation step in the existing rootfs
cache pipeline. This is a supported lazy-discovery optimization, not a measured
application-launch speedup. No runtime service, timeout, readiness signal,
application screen, graphics policy, or vCPU setting changes.

No Simulator/device interaction, installation, image build, rootfs replacement,
shared library build, or commit was performed. Existing dirty/untracked work and
concurrent agents' changes were left intact. Native test fixtures were compiled
in temporary directories only. Image evidence below was read with debugfs
without `-w` from an existing captured diagnostic image, not a live disk.

## Prior Work And Evidence

Read `docs/gtk-input-latency-profile.md` and
`docs/phosh-graphics-priority-profile.md` before implementation.

- Custom GLib 2.88.3-r1 modifies MIME magic matching in
  `scripts/patches/glib-pinecone-mime-search.patch`; it does not supply module
  registries. Its package includes `gio-querymodules` and `glib.trigger`.
- The musl startup symbol index, relocation cache, GNU-chain hash reuse, and
  optional startup counters already exist. Normal staging remains r10; rejected
  r11 pointer-identity results are not promoted or reinterpreted.
- Existing cache generation uses guest fc-cache, pixbuf-query-loaders and GTK3
  input-module queries. The image builder compiles schemas and MIME data and
  optionally generates icon caches using a host tool, twice. No existing shell
  build path invokes `gio-querymodules`, although `glib.trigger` requires it for
  `/usr/lib/gio/modules` and `/usr/lib/gtk-4.0` when present.
- Read-only inspection of
  `/tmp/pinecone-gtk-latency-20261031/repeat-captured.ext4` found four GIO modules
  (`libdconfsettings.so`, `libgiognomeproxy.so`, `libgiognutls.so`,
  `libgiolibproxy.so`) and **no giomodule.cache**. The cached Alpine networking APK
  supplies modules but no registry. `animations-on.log` maps all four modules.
  These mappings are already present at application-run entry; they do not
  attribute the subsequent 9.14 seconds to module loading.

GLib's `g_io_modules_scan_all_in_directory_with_scope()` initializes uncached
modules through `g_type_module_use()`. A valid entry enables lazy initialization
when its extension is requested. A module with no entry, or a newer change time,
retains eager discovery. The fix restores that existing contract; it does not
disable TLS, proxies, settings, or any extension. See
[GLib 2.88.3 giomodule.c](https://raw.githubusercontent.com/GNOME/glib/2.88.3/gio/giomodule.c).

## Changed Files

1. `scripts/generate-aarch64-rootfs-caches.sh`: run the shipped ARM64
   `gio-querymodules` inside the staging chroot for both trigger directories.
   Both Linux and Lima paths use the same function. Lima returns only registry
   files, not module binaries. An absent registry after a successful empty query
   removes an obsolete host-staging registry. Missing query tools and nonzero
   query exits fail staging. Pass the Linux sudo root path as an argument.
2. `scripts/test-graphical-input-cache.py`: extend existing staging mocks to cover
   both query directories, native/Lima generation and copyback, empty results,
   failures, missing tools, preserved module bytes, and quoted sudo paths.
3. `scripts/gio-module-cache-regression.c`: small real GIO module and scan client
   verifying initialization timing and the usable extension's type/priority.
4. `scripts/test-gio-module-cache.py`: compile/run that fixture with the installed
   native GIO; test cache creation, eager/lazy paths, invalidation and removal.
5. `docs/app-startup-agent-report.md`: this handoff.

## Verification

- `python3 scripts/test-graphical-input-cache.py`: **12 passed**, about 6 seconds.
  Chroot, sudo and Lima are mocked; no builder or guest was started.
- `python3 scripts/test-gio-module-cache.py`: **5 passed**, about 1.2 seconds.
  Native GLib **2.88.2**, C compilation with `-Wall -Wextra -Werror`.
  An uncached scan initializes the fixture immediately; a cached scan does not.
  Requesting the extension initializes it and permits constructing its object.
  Missing entries and newer module ctime preserve eager fallback. An empty
  query directory removes its obsolete registry.
- `bash -n scripts/generate-aarch64-rootfs-caches.sh`: passed.
- Scoped `git diff --check`: passed.

No ARM64 package execution, complete image build, or UI/performance validation
was run. Native tests prove the cache mechanism, not the guest latency benefit.

## Concrete Unresolved Paths

### GApplication And Service Waits

The corrected Text Editor capture remains 3.27 s exec-to-constructor, 9.14 s
application-run to startup after-handler, and 23.68 s exec-to-first-after-paint.
The 0.22 s constructor-to-run interval and module mappings do not distinguish
loader work, earlier constructors, and module initialization. Settings' 5.50 s
pre-constructor, 10.98 s startup and 5.39 s activate observations remain exploratory.

The specific synchronous paths in GLib 2.88.3 are
`g_application_impl_register()` -> `g_bus_get_sync(G_BUS_TYPE_SESSION)` and
`g_application_impl_attempt_primary()` ->
`g_dbus_connection_call_sync(..., "RequestName", ..., -1, ...)`.
The non-primary path additionally calls `g_dbus_action_group_sync()`.
The logs contain no paired entry/exit evidence proving any of these dominates.
Preserve their service discovery, uniqueness, cancellation, and timeout behavior.
See [gapplicationimpl-dbus.c](https://raw.githubusercontent.com/GNOME/glib/2.88.3/gio/gapplicationimpl-dbus.c).

Session-level `prepare_system_bus()` and `prepare_input()` run before Phoc/Phosh,
not once per cold app. Settings prewarming is already opt-in. No redundant
per-launch initialization or required service safe to remove was established.
The next attribution boundary is GApplication registration versus the startup
signal's application/toolkit handlers, with synchronous calls individually timed;
the shared latency probe is owned by another agent and was not edited here.

### Other Cache Gaps

The captured image has Adwaita and hicolor themes but neither icon-theme.cache;
the guest `gtk-update-icon-cache` executable exists. The builder's host-only
optional generation explains a possible omission, but no icon-lookup timing was
captured. Guest-side icon-cache generation/validation is a separate remaining
change, not bundled into this GIO fix.

Fontconfig cache files exist; several have guest-session timestamps/ownership
while others retain build timestamps. The unresolved path is fontconfig cache
validation/rebuild after image staging, not proof of missing fonts or universally
invalid caches. Inspect directory identity/mtime and per-directory cache hits
before changing font selection or timestamps. MIME's compiled cache also exists.

## Integration, Risks And Remaining Work

The owner must run the normal cache stage/image integration and verify the exact
guest GLib 2.88.3-r1 registry entries and cache/module timestamps survive copyback
and ext4 creation. No manual module list or host-generated GIO cache is shipped.
Legacy modules without query metadata retain ordinary eager fallback; upstream
query diagnostics and exit semantics remain unchanged.

Then verify Settings and Text Editor cold starts, settings persistence, TLS/proxy
availability, icons/fonts, and first-frame correctness with two vCPUs and zero
fallbacks. Compare matched launches with unchanged instrumentation and reverse
order before reporting any speedup. Lazy loading can shift required module work
to first use; it does not eliminate it or establish lower total CPU work.

The measured insertion 77 ms, insertion-to-before-paint 106 ms, frame cycle
307 ms and insertion-to-after-paint 417 ms remain overlapping guest wall-clock
phases, not CPU attribution. Disabling GTK4 animations did not help and is not
part of this change. No graphics/input latency improvement is claimed.

## Icon Cache Follow-Up (2026-10-31)

New evidence supplied by the integration owner: Text Editor PID 689's guest
strace repeatedly reports ENOENT for hicolor/icon-theme.cache while scanning
thousands of icon directories. Read-only inspection of the authorized builder
snapshot `/tmp/pinecone-gtk-abi.ext4` confirms both hicolor and Adwaita have
index.theme but no icon-theme.cache. The guest has gtk-update-icon-cache;
gtk4-update-icon-cache is a symlink. This closes the evidence gap noted above
and justifies generating the missing indexes, not a claimed startup speedup.

Changed files for this follow-up only:

- `scripts/generate-aarch64-rootfs-caches.sh`: generate and validate native
  index-only caches for installed themes with index.theme, after pixbuf loader
  registration. Prefer the shipped gtk-update-icon-cache, accepting the GTK4
  tool name when that is the available executable. Missing tools, failed
  generation, empty/missing output, and failed validation stop staging. Linux,
  sudo and Lima use the same function. Copy back caches only, preserving icon
  and index.theme contents. Refresh copied cache mtimes to their parent theme
  directory mtimes; no theme contents or timestamps are normalized here.
- `scripts/test-graphical-input-cache.py`: add five tests, including both theme
  names, spaces in paths, unthemed directories, GTK4-only profiles, all execution
  paths, missing tools/output, failures, and copyback timestamp freshness.
- `scripts/icon-theme-cache-regression.c`: small display-free public GTK API
  lookup fixture, compiled separately against GTK3 and GTK4.
- `docs/app-startup-agent-report.md`: this evidence and handoff.

Exact GTK 4.22.4 source at `gtk/gtkiconcache.c:100` rejects a cache whose mtime
is less than the theme directory mtime. Cache-only tar extraction can advance
that directory mtime, so preserving the old archive mtime alone is insufficient.
The main image builder already calls this generator after icon staging and its
source timestamp normalization. The optional host-cache passes were not edited;
the native generation now force-replaces their output when present.

Validation:

- `python3 scripts/test-graphical-input-cache.py`: **17 passed**. These are
  staging mocks, including the previous GIO/input coverage.
- `python3 scripts/test-gio-module-cache.py`: **5 passed**; shell syntax and
  scoped `git diff --check` also pass.
- Two small fixtures compile with `-O2 -Wall -Wextra -Werror` and pkg-config
  gtk+-3.0 / gtk4 on pinecone-builder. Executed via chroot with the exact
  snapshot libraries, without a display: eight before/after lookup results
  match exactly for Text Editor, Settings, document-open-symbolic and
  edit-copy-symbolic across hicolor/Adwaita and both GTK versions. Adwaita's
  inherited hicolor Text Editor lookup also succeeds with both versions.
- The exact guest cache tool generates both files and `--validate` succeeds.
  All non-cache regular theme-file SHA256 hashes match before/after.
- No strace is installed on the builder; no dependency install was attempted.
  These tests establish generation, format validation and lookup correctness,
  not syscall-count reduction or measured launch latency.

Native reproduction workspace: `/tmp/pinecone-icon-cache.dKlieK` on
pinecone-builder. It contains only a temporary extraction, fixtures and reports;
debugfs read the source image without `-w`. Fixture invocation after compilation:

```sh
sudo chroot "$work/root" /tmp/icons-gtk3 /usr/share/icons hicolor org.gnome.TextEditor org.gnome.Settings
sudo chroot "$work/root" /tmp/icons-gtk4 /usr/share/icons Adwaita document-open-symbolic edit-copy-symbolic
```

Host handoff: `/tmp/pinecone-icon-cache-final/icon-caches.tar`, containing only
`usr/share/icons/{hicolor,Adwaita}/icon-theme.cache`. Reports, the theme input
manifest and cache hashes are adjacent. SHA256:

```text
hicolor b6425e83cd68e727dce2720035173bb2574822caf87733f5f2fa25c6b07b29bc
Adwaita ca5bddfc954b04be0b2637c3ebc3a124415f6af7013c0bcc284a60272898610a
```

Main owns installation: use only with matching theme contents, and ensure the
cache mtime is not older than its theme directory after offline copying. For
future images, run the updated generator rather than reusing this snapshot's
caches. Theme/icon changes require regeneration. Remaining work is main's guest
strace comparison and icon/UI validation, including cold Text Editor startup;
the separate reported 4.5-second first-key wait remains unattributed here.
No Simulator, source image, production staging pin, dependency package or theme
content was modified, and no shared image build was run.
