# Packages for Phosh

Packages is a small C/GTK3 frontend to the guest's real APK 3 command-line
interface. It runs inside Alpine, not in Swift or an iOS overlay.

## Supported operations

- Refresh signed repository indexes through the existing host network bridge.
- Browse Home, Sources, Updates, Installed, and Search tabs.
- Discover curated Productivity, Files & Images, Terminal Tools, and Development
  categories. These are editorial selections, not claims of tested compatibility
  or automatically imported AppStream categories.
- Inspect versions, descriptions, sizes, licenses, sources, and dependencies
  from real APK metadata.
- Queue multiple installs, removals, or updates, then approve APK's proposed
  transaction. A queue contains one operation type so preview and apply use the
  same single APK solver invocation. Mixed-operation queues are rejected rather
  than split into misleadingly atomic transactions.
- Add, enable, or disable HTTP/HTTPS sources. Comments and advanced APK source
  entries are preserved; advanced entries are read-only in this UI. File
  replacement uses the loaded etag to reject concurrent edits and retains a
  backup. Adding a source does not import keys or relax signature checks.
- See live transaction output and errors in Activity without blocking GTK.
- Use Squeekboard for search input. The desktop ID is
  `me.gmoran.pinecone.packages.desktop`.

The catalogue uses APK's JSON query output, not scraped terminal columns.
Commands use argument vectors, never a shell constructed from user input.
The UI renders 10 result rows per page, preserves installed-version information, and
avoids opening repository indexes for installed-only queries. APK itself owns
dependency resolution, database locking, archive verification, and filesystem
changes. Closing the window during a running operation is blocked so the UI
does not abandon a write transaction. A pending queue survives cancellation of
the confirmation dialog and requires confirmation before being discarded on
window close. It is session-local, not persisted across application crashes.
Search runs on submission, not every keystroke. Home and Installed use local
data rather than scanning all repository indexes on every tab change.
Installed-package detail queries also bypass repository indexes. Detail records
are cached for the session and invalidated after source changes, refreshes, or
transactions; update candidates do not reuse installed-version detail records.
After a failed write transaction, installed state is reloaded because APK may
have made partial progress. The queue is retained for review and retry.

## Image integration

`stage-alpine-graphical-rootfs.sh` exports the exact archive selection, including
the patched runtime overlays. `register-rootfs-packages.sh` asks APK to install
that selection in an isolated build root with normal signature verification.
Its file-ownership database, package scripts, triggers, trusted public keys, and
world file are copied into the staged guest. No private signing key is shipped.
Initial package scripts remain disabled during registration, consistent with
the existing image builder; the builder generates the required runtime caches
against the staged ARM64 binaries.

The `.pinecone-platform` virtual package depends on exact versions of every
bundled package. These compatibility constraints retain the patched graphics
and interpreter-support runtime during ordinary package transactions. The UI
does not offer removal of bundled packages or a whole-system upgrade. Guest
root can deliberately change world constraints: this is not a security sandbox.
Packages needing a different base version require a reviewed image rebuild.

New packages and APK metadata are stored on `rootfs.ext4`. Normal host stop/reboot
flushing still matters. Boot preserves `/etc/apk/repositories` instead of
overwriting user configuration. The initial repositories explicitly use the
host's Alpine package proxy; signature checks remain enabled.

## Verification

Run the offline staging checks with:

```sh
python3 scripts/test-package-manager-packaging.py
python3 scripts/test-browser-packaging.py
python3 scripts/test-graphical-overlay-dependencies.py
python3 scripts/test-graphical-input-cache.py
```

The frontend build runs `pinecone-packages --self-test`; the image-cache build
also checks its dynamic linker dependencies and APK database consistency in
the actual staged root.

On the aarch64 Linux build VM, run the disposable-image transaction test as
root. It copies the supplied image, mounts only that copy, refreshes indexes,
installs/runs/removes `tree` and `htop` in a batch, verifies persistence across unmount/remount, and
checks that an available stock libc cannot replace the pinned patched libc:

```sh
bash scripts/test-package-manager-transactions.sh /path/to/rootfs.ext4
```

APK may also install optional `install_if` packages as part of its normal solver
transaction; these are shown in the confirmation. The test verifies Phoc and
the patched loader hashes remain unchanged. Simulator UI verification is a
separate check, not implied by the native Linux image test.

## Limits

This is a package utility, not an AppStream storefront or an Android APK
installer. Repository queries and transactions still execute through the
guest CPU interpreter and can be slow. There is no new background update
service, privilege escalation daemon, CPU fallback, or graphics backend change.
The image must be rebuilt with a registered APK database; placing the UI alone
into an older, extraction-only rootfs is not supported.

## Initial frontend integration check, 2026-10-26

- 649 core tests passed; 39 offline packaging/input/dependency tests passed.
- The disposable image test passed refresh, install, execution, remount,
  removal, and rejection of stock musl 1.2.6-r6 in place of patched 1.2.6-r8.
- In the iOS Simulator, Phosh booted and unlocked. Packages launched, accepted
  Squeekboard input, refreshed 29,181 repository packages, and completed an
  `htop` install/remove cycle through both confirmation dialogs. Native
  interpreter fallback remained zero.
- The final bundled rootfs SHA-256 is
  `0ee1edf9ed60596d8970a5d267b8efdfdb0403e08e45f4a2ad9273e7ca285c5b`.
- Repository scans remain slow under interpretation. A transient black
  rectangle was also visible at the focused GTK search entry; submitted query
  text and results rendered correctly. This graphics artifact is not fixed by
  the package-manager work.

## Cydia-style interface validation, 2026-10-26

- Frontend builds with warnings treated as errors. Its self-tests cover package
  metadata, input validation, protected packages, queue argument construction,
  source toggling, comment preservation, and concurrent source edits.
- The same self-tests passed a trap-based UndefinedBehaviorSanitizer build.
  AddressSanitizer was unavailable because its runtime libraries are not
  installed in the builder; no builder packages were changed to add them.
- All 39 offline packaging/input/dependency checks passed.
- The final image passed batch install/remove, executable checks, remount
  persistence, update-plan validation, and the pinned-libc rejection test.
- Simulator UI checks completed boot, full-height unlock, package discovery,
  source refresh, detail pages, install confirmation, installed-state display,
  and removal confirmation. Both transactions completed and cleared the queue;
  interpreter fallback remained zero.
- Secondary and disabled label colors are opaque, and icon names match the
  bundled Adwaita theme. No CPU, scheduler, or graphics backend changes are part
  of this redesign.
- The final Release build was reinstalled, booted, unlocked, and visually
  checked. The gray secondary-text blocks were absent. Source disable/enable
  was verified in the guest, with both default sources restored afterward.
- Bundled rootfs SHA-256:
  `146ecf45594aa005f62c1003fd3e094f656cc67090cf71ccc5c88ddd3d8c103e`.

Updates are limited to additional packages compatible with the pinned base.
The UI is still an Alpine package manager, not an iOS/Debian package installer.
