# Text Editor 50.1-r1 Candidate

Date: 2026-10-31. Package/build/staging owner report; editor-path fix and semantic
tests are owned by Harvey. No Simulator actions, guest installs, image writes,
shared dependency changes, unrelated pin updates or commits were performed here.

## Ready Artifacts

- Live validation executable: `/tmp/pinecone-diagnostic-transfer/gnome-text-editor`.
- Complete handoff: `/tmp/pinecone-text-editor-r1-final/`, including APKs,
  readelf, build logs, compiler/package inventory, guest ABI and semantic logs.
- Overlay package:
  `artifacts/alpine-packages/pinecone-gnome-text-editor/aarch64/gnome-text-editor-50.1-r1.apk`.
- Exact original snapshot executable retained separately at
  `/tmp/pinecone-text-editor-r1-final/gnome-text-editor-baseline`.

SHA256:

```text
candidate b7fbcecdf350d1586fe8030a81e54ada6cc35099ef1c744400987a310c081d9a
APK       911f604636aa6c5da101fe103924fd086824b7c6beacd07e451fe4735510d277
baseline  75688be3bddac68aa1f3705888c3ee5347edb9f3f47d1d3f4b6c0b824566494d
patch     125cb1392cb4fc21dd01e11e6a431637b2fe558d510278c73de6c96d67190213
```

The exact 50.1 GitLab source archive supplied by main matches the preserved
Alpine recipe's SHA512. Only `editor-path-literal.patch` is applied, replacing
the shell-quoted wordexp identity round trip with a literal copy. No tracing
code, GtkSourceView modification or other application change is linked in.
Relative-path home joining and other path behavior remain owned/tested by Harvey.

## Source Integration

Files changed by the package/build task:

- `scripts/alpine/gnome-text-editor/APKBUILD`: 50.1-r1 recipe, pinned source and
  patch checksums, standard LTO/release packaging, four-job default.
- `scripts/build-pinecone-text-editor.sh`: native aarch64 build using an existing
  dependency/signing environment, supplied source archive and new output
  directory. No dependency installation, package refresh, production publish or
  image build. Validates package identity, extracts the exact packaged binary,
  rejects RPATH/RUNPATH, tracing dependencies and remaining wordexp imports,
  and saves dependencies/checksums/test logs. Required validation tools are
  checked before starting rather than silently skipping upstream tests.
- `scripts/test-text-editor-guest-abi.sh`: private read-only loop mount of the
  offline guest, scratch-only /tmp bind, empty preload environment, loader and
  --version checks, package inventory and automatic unmount/loop cleanup.
- `scripts/stage-alpine-graphical-rootfs.sh`: default-on Phosh overlay through
  `PINECONE_USE_PATCHED_TEXT_EDITOR=1`, explicitly disabled with `0`. Promoted
  after main's successful live smoke test. No unrelated overlay versions changed.
- `scripts/test-graphical-overlay-dependencies.py`: editor included in actual
  dependency rejection tests; verifies default overlay behavior, explicit stock
  opt-out, missing-overlay failure and preservation of the cached stock pin.
- `scripts/test-browser-packaging.py`: explicitly disables the editor overlay
  in stock browser fixtures, like the other production overlays.
- `docs/text-editor-package-report.md`: this handoff.

Harvey separately owns `scripts/text-insertion/editor-path-literal.patch`,
`test-path.sh` and `test-path.c`; these were consumed without modification.

## Build And ABI

Built in the existing private chroot on pinecone-builder:
`/home/gmoran.guest/pinecone-phosh-r9-final.FJehKE/chroot`.
The source/recipe copy is `/pinecone-editor-recipe` inside it. Output is
`/text-editor-r1-candidate`. Thirteen dependency additions were confined to this
private root, with no upgrades. The desktop-file validator was added after the
first build, then Meson was reconfigured and both metadata tests rerun without
recompiling or changing the delivered executable. The final helper requires it.

Native reproduction with installed recipe dependencies and abuild signing:

```sh
bash scripts/build-pinecone-text-editor.sh /path/gnome-text-editor-50.1.tar.gz /tmp/new-editor-build
sh scripts/test-text-editor-guest-abi.sh /tmp/pinecone-gtk-abi.ext4 /tmp/new-editor-build/gnome-text-editor /tmp/new-editor-abi
```

Build headers: GLib 2.90.0, GTK 4.24.1, SourceView 5.22.0, Adwaita 1.10.0,
libspelling 0.4.10. Upstream source bounds APIs to GLib 2.80, GTK 4.20,
SourceView 5.16 and Adwaita 1.8. This is a checksum-pinned reproducible recipe
with a recorded build environment, not a claim of bit-identical output across
arbitrary toolchains. No newer runtime package is required or staged.

Exact guest `/tmp/pinecone-gtk-abi.ext4` validation passes using:

- GLib 2.88.3-r1
- GTK 4.22.4-r0
- GtkSourceView 5.20.0-r1
- libadwaita 1.9.3-r0
- libspelling 0.4.10-r0
- libeditorconfig 0.12.11-r0

All ELF dependencies resolve. --version confirms guest GTK/SourceView versions
without starting a display or session. Binary has no wordexp/wordfree undefined
symbols, build-path RPATH/RUNPATH or text-tracing library dependency. The original
executable was extracted with read-only debugfs; the source disk is unchanged.

## Verification And Remaining Gate

- Both upstream Meson tests pass: desktop file and AppStream metadata.
- After promotion, all 16 graphical overlay tests and 20 browser packaging tests
  pass, including default-on missing-overlay failure and stock opt-out coverage.
- Real Phosh closure validation with `ARM64VIZ_GRAPHICAL_VALIDATE_ONLY=1` and
  `PINECONE_USE_PATCHED_TEXT_EDITOR=1` passes without extraction or pin changes.
  A second complete audit after promotion, with that variable unset, also passes.
- Shell syntax and scoped whitespace checks pass.
- Harvey reports original/patched helper differential and real text-buffer
  notification tests pass for three HOME configurations, literal/null/Unicode/
  metacharacter paths, insertion/deletion/selection replacement/undo/redo and
  committed Unicode. Both private GTK and the exact stock guest closure pass;
  patched subtitle callbacks make zero wordexp calls.

Main completed normal live smoke: launch, render a saved seven-byte document,
guest keyboard qwe, backspace to qw, close/discard and return Home. Phosh PID 129
remained running with zero fallback; installed executable hash matches the
delivered candidate. At main's explicit request the Phosh default is promoted.
Main still owns corrected before/after latency measurements. The source
eliminates an unnecessary subprocess, but instrumentation can amplify its cost:
no whole-application or first-key speedup is claimed by this build.
