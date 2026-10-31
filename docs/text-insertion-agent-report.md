# Text Insertion Attribution (Task 2)

## Final Fix and Focused Test Results

**Implemented:** `scripts/text-insertion/editor-path-literal.patch`, SHA-256
`125cb1392cb4fc21dd01e11e6a431637b2fe558d510278c73de6c96d67190213`.
It applies without fuzz to Text Editor 50.1 `src/editor-path.c` SHA-256
`983c5c958086a2e2cbd87a709dbbdec84bb34cdb142cb4a2fd5dff67ceb92e08`.
Patched source SHA-256:
`a659d6616ad5eb24b84a2939f27ac221c29c4edafe00a2d50c62737df5c336ed`.

The exact source first calls `g_shell_quote(path)`, then
`wordexp(escaped, ..., WRDE_NOCMD)`. The quotation makes the successful result
the **original literal pathname**, including `$`, `~`, globs and command-looking
characters. The patch replaces that identity round trip with `g_strdup(path)`.
It preserves NULL handling, relative-to-home joining, absolute paths, existing
home collapsing, portal handling and the non-Unix branch. It does not introduce
a cache, alter filename interpretation, skip notifications, or change input,
undo, spelling, accessibility, persistence or logout inhibition. Existing
home-prefix matching behavior is intentionally unchanged.

### Exact First-Modified Route

All editor locations below are in the pristine 50.1 tree at
`/tmp/pinecone-text-insertion-agent/gnome-text-editor-50.1/`:

```text
gtk_text_buffer_real_insert_text
  -> g_signal_emit(CHANGED)
  -> editor_document_changed                     src/editor-document.c:358
  -> parent changed / gtk_text_buffer_real_changed
  -> gtk_text_buffer_set_modified(TRUE)
  -> modified-changed (only when modified changes)
  -> editor_page_document_modified_changed_cb    src/editor-page.c:182
  -> g_object_notify_by_pspec(PROP_SUBTITLE)
  -> page subtitle -> window label GBinding      src/editor-window.c:1077
  -> page get_property(PROP_SUBTITLE)            src/editor-page.c:812
  -> editor_page_dup_subtitle                    src/editor-page.c:1131
  -> _editor_path_collapse(native parent path)   src/editor-page.c:1176
  -> _editor_path_expand                        src/editor-path.c:39
  -> g_shell_quote + wordexp(WRDE_NOCMD)         src/editor-path.c:50-54
```

The two GTK functions are at lines 3033 and 3619 in the local exact
`/tmp/pinecone-text-insertion-agent/gtktextbuffer-4.22.4.c`.
This route lies inside the measured GTK-parent tail after spelling returns.
The previously proposed inhibition route was a source-based candidate, **not a
confirmed cause**, and is superseded as the leading explanation by the shell
pipe evidence and literal-path source call.

### Evidence and Caveats

Main's subsequent PID 689 strace excerpt in the named validation `pinecone-uart.log`
shows repeated main-thread pipe reads returning eight bytes `x\0/root\0` after
approximately 6-8 seconds, while child processes load GTK/LLVM dependencies.
This is consistent with the shell expansion route; the full shell/exec syscall
capture and manual UI correlation are owned by main.

**Do not claim those multi-second durations as stock production latency.**
GTK-linked diagnostic LD_PRELOAD entries are inherited across shell exec and
can amplify its startup. The GTK latency probe and insertion commit/wait shims
all require attention in an instrumented comparison. Gibbs owns diagnostic
preload inheritance; this task did not edit `guest-gtk-latency.c` or launchers.
Constructor executable gating alone does not prevent dependency loading before
the constructor. The source fix removes the unnecessary shell call regardless
of instrumentation, but its clean end-to-end benefit still needs main's stock/
candidate comparison. No actual preedit IME, full editor persistence or rendered
UI equivalence is claimed by these headless tests.

### Passed Tests

Command (existing build-only Linux environment, no package installation):

```sh
sh /Users/gmoran/Documents/Projects/arm64viz/scripts/text-insertion/test-path.sh \
  /tmp/pinecone-path-editor-50.1/gnome-text-editor-50.1 \
  /tmp/pinecone-path-test-next
```

The test compiles the **actual original and patched source**, renaming only the
reference functions and counting its calls to real libc `wordexp`. It compares
expand/collapse outputs for NULL/empty, absolute/relative paths, home itself,
home children/prefix siblings, spaces, quotes, backslashes, shell metacharacters,
control bytes, non-UTF-8 filename bytes, composed/decomposed Unicode and 127
additional byte combinations. It runs with normal, space-containing and `/`
HOME values. Original and patched results match; patched calls never increment
the wordexp counter. `nm -u` confirms no expansion/process API imports remain
in the patched helper.

Real GtkTextBuffer notification callbacks invoke the patched subtitle helper
during insertion, deletion, selection replacement, undo/redo and committed
Unicode/decomposed-character edits. Text and notification assertions pass, with
zero wordexp calls during those lookups. This is a focused callback harness,
not the full Text Editor window implementation.

All tests passed both on the builder with private GTK 4.22.4 and in a read-only
chroot of `/tmp/pinecone-gtk-abi.ext4` using its **stock guest libraries**. The
guest test used no diagnostic preloads. Its first harness attempt lacked a
usable `/dev/null` for the original helper's shell; a private tmpfs `/dev/null`
resolved that harness issue. Image mounts were `ro,noload`, test-file binds
were read-only, and all mounts were released. No live app or disk was changed.

Builder output directory: `/tmp/pinecone-path-test-v1/`.
Exact logs: `plain-home.log`, `space-home.log`, `root-home.log`,
`guest-plain-home.log`, `guest-space-home.log`, `guest-root-home.log`.
Every log ends with:

```text
ok 1 /editor-path/literal-differential
ok 2 /editor-path/edit-notifications
```

Additional evidence: `patched-imports.txt`, `SHA256SUMS`, `original.o`,
`patched.o`, `test-path`, and both source copies in that directory.
Host evidence archive: `/tmp/pinecone-text-insertion-agent/path-fix-tests.tar.gz`.

### Handoff and Files

Kepler owns package/build/staging. His delivered candidate is
`/tmp/pinecone-diagnostic-transfer/gnome-text-editor`, SHA-256
`b7fbcecdf350d1586fe8030a81e54ada6cc35099ef1c744400987a310c081d9a`
(hash independently checked here). Kepler reports exact guest loader/version
checks passed, no wordexp/wordfree imports, and no tracer dependencies. Main
reports the candidate installed and owns the remaining stock/candidate UI,
persistence, IME and performance checks. No further attribution probes are
being added.

Changed in this final source-fix turn under `scripts/text-insertion/`:
`editor-path-literal.patch`, `test-path.c`, `test-path.sh`,
`path-test-config/config.h`. Updated this report.
Before the narrowed final instruction, this turn also added the libc-only
wordexp recorder/fixtures: `trace-wordexp.c`, `build-wordexp.sh`,
`test-wordexp.c`, `test-wordexp.sh`. It is diagnostic only, always forwards the
original operation, and has only musl libc as a DT_NEEDED dependency. Eleven
literal/flag forwarding cases and executable gating passed. Its optional host
artifact and handoff are under
`/tmp/pinecone-text-insertion-agent/artifacts-wordexp-v1/`; no interposition fix
was deployed or substituted for the source patch. All unrelated work and the
previous frozen tracing binaries were preserved; no commit was made.

## Captured Stall: Notification Tail, Inhibition Candidate

Input: `/tmp/pinecone-agent-integration-20261031/insertion-lifecycle-uart.log`.
The existing analyzer validates PID 591, 67 records and ten roots, with no
dropped/limited records. User-confirmed maps include all three frozen libraries,
private GTK 4.22.4 and actual libspelling.

The important new boundary is **after** `spelling.commit.after-insert` returns:

| Edit | Whole root wall | GTK-parent wall | Tail after spelling returns |
| --- | ---: | ---: | ---: |
| Restoration, root 1 | 5139.73 ms | 5139.13 ms | **5134.18 ms** |
| First `q`, root 3 | 4508.01 ms | 4502.55 ms | **4499.20 ms** |

GTK-parent guest thread CPU is 110.43/128.65 ms respectively. These clocks are
not exclusive host CPU attribution and do not establish a kernel wait alone.
SourceView cursor/bracket work follows the long parent span; spelling's two
callbacks total only 1.51 ms for first `q`. Neither explains the stall.

Exact GTK 4.22.4 `gtk_text_buffer_real_insert_text` performs history recording,
before-insert callbacks, B-tree insertion and after-insert callbacks **before**
its final `g_signal_emit(CHANGED)` and `g_object_notify_by_pspec(cursor-position)`.
Consequently the multi-second tail is in those notification routes (or time
descheduled between them), not in the preceding history/B-tree/spelling work.
Local exact source: `/tmp/pinecone-text-insertion-agent/gtktextbuffer-4.22.4.c:1255`.

The leading **unconfirmed** route is the first dirty transition:

```text
gtk_text_buffer_real_changed -> gtk_text_buffer_set_modified(TRUE)
  -> modified-changed -> editor_page_document_modified_changed_cb
  -> notify::is-modified -> page_notify_is_modified_cb
  -> editor_window_update_inhibit -> gtk_application_inhibit(LOGOUT)
  -> gtk_application_impl_wayland_inhibit
  -> gtk_application_impl_dbus_inhibit
  -> g_dbus_proxy_call_sync(portal, "Inhibit", ..., G_MAXINT, ...)
```

Editor source locations (under the exact 50.1 tree in the host source directory):
`src/editor-page.c:182`, `src/editor-window.c:1137`, `:1178`, `:1243`.
The window helper skips additional requests when its inhibit cookie is nonzero,
which is consistent with cold/first-dirty versus warm behavior but is not runtime
proof. GTK's [D-Bus inhibition implementation](https://raw.githubusercontent.com/GNOME/gtk/4.22.4/gtk/gtkapplication-dbus.c)
passes `G_MAXINT`; it does **not** set a five-second timeout. Its
[Wayland implementation](https://raw.githubusercontent.com/GNOME/gtk/4.22.4/gtk/gtkapplication-wayland.c)
can return a local cookie even without a successful underlying D-Bus cookie.
The probe therefore records the nested D-Bus outcome, not just the outer cookie.
Do not disable inhibition, accessibility, clipboard, persistence or spelling.

### One-Library Next Artifact

Host: `/tmp/pinecone-text-insertion-agent/artifacts-wait-v1/libpinecone-text-wait.so`

SHA-256: `c545dd02ce449c681a9a7b74bb8ba41bec847f2a276ca441b05f3fbd3232f963`.

Builder: `/tmp/pinecone-insertion-wait-v3/libpinecone-text-wait.so`.
Source: `scripts/text-insertion/trace-wait.c`.
Rebuild: `sh scripts/text-insertion/build-wait.sh EXISTING-TRACE-RUNTIME NEW-OUTPUT`
inside the existing build-only Linux environment. No GTK/editor rebuild or
package transaction is needed. The existing three libraries remain unchanged.

For a user-owned subsequent editor exec, place this library alongside those
three and append its absolute guest path to the temporary wrapper's **final**
`PINECONE_GTK_PRELOAD`. Preserve private GTK/SourceView paths and existing probe/
Pixman preloads. Keep `PINECONE_TEXT_INSERTION_TRACE=1`. No VM reboot is needed;
this task has not attached to, restarted or modified the live editor.

It adds nested PCEDIT1 spans for external `g_signal_emit`, notify-by-pspec,
inhibit/uninhibit, synchronous GDBus proxy/connection/message calls, `g_poll`,
and GLib condition waits. PCWAIT1 metadata joins by PID/span ID and records
object type, signal/property, D-Bus service/interface/method, timeout/result/error,
and caller module-relative offset. No text, message bodies, paths or reason
strings are captured. Only the existing recorder's main-thread active edits
produce records; there are at most 2048 metadata records. Allocation, output,
symbolization and stack walking are not added to edit instrumentation (ordinary
original functions still do their normal work). Symbol resolution is at startup;
symbolization/output is on normal exit. Overflow/truncation fails analysis.

Collect both prefixes on normal exit, then:

```sh
python3 scripts/text-insertion/analyze-wait.py /path/to/complete-editor-log
```

`arg` is milliseconds for D-Bus/poll, absolute monotonic microseconds for
`g_cond_wait_until`, or flags for inhibit. `INT64_MIN` means not applicable.
`result` is the original return for poll/timed wait, a non-null success indicator
for D-Bus, the returned cookie for inhibit, or the input cookie for uninhibit.
Detailed signal quarks and all variadic arguments/return storage are forwarded.
Hidden/internal calls and raw futex operations can bypass these symbols; missing
wait spans are not proof of no waiting. Main owns syscall strace, not this task.
Caller offsets are return PCs, not full backtraces; compiler tail calls can
attribute a return address to an outer caller. The nested timing and signal/
property metadata, rather than a return PC alone, identify the measured route.

The next decision is concrete: if the nested `Inhibit` span consumes the tail,
use its service/result and main's syscall capture to identify the slow responder
before changing the editor's inhibition lifecycle. A plain idle deferral would
only move the stall and can leave a logout-protection gap; it is not a fix.
Otherwise follow the measured changed/property span and caller offset. No
performance patch is justified by the evidence available at this point.

### Verification and Changed Files

The final artifact passed the read-only image dependency gate with GLib 2.88.3,
Pango 1.57.1 and private GTK 4.22.4, including text/deletion/selection/undo/redo,
committed Unicode/decomposed text, highlighting, restoration and callback tests
with tracing off/on and standalone roots. Builder results:
`/tmp/pinecone-insertion-guest-wait-abi-v2/`.
The first minimal loader fixture exposed linker `--as-needed` dropping GTK
because the wrapper uses dlsym; the build now explicitly retains GTK as a
dependency. The final artifact passes that loader fixture too.

Synthetic forwarding tests cover variadic signal return/arguments, cookies,
error/cancellation propagation, serial output, pointer ownership, errno,
condition waits, foreign-thread exclusion and payload omission. These validate
the shim, not a live portal. Final logs: `/tmp/pinecone-insertion-wait-test-v2/`.
Six analyzer tests cover joins, duplicates, mismatches, missing metadata,
truncation/saturation and existing timing invariants. Actual IME/preedit,
persistence/UI and stall attribution remain user runtime gates.

Added this turn under `scripts/text-insertion/`: `trace-wait.c`, `build-wait.sh`,
`test-wait.c`, `test-wait.sh`, `analyze-wait.py`, `test-wait-analysis.py`.
Updated: `test-guest-abi.sh` (optional fourth library), this report. External
artifact: `artifacts-wait-v1/HANDOFF.txt` and the single DSO. No other scope,
frozen binary, shared launcher, runtime disk or live app was modified.

## Guest Dependency Gate: Passed

The frozen three-library trace deployment below passed against the actual
dependency set in the builder's `/tmp/pinecone-gtk-abi.ext4`, not just the
builder libraries. The image was initially unmounted; testing used a private
mount namespace, a read-only loop device and ext4 `ro,noload` (reported as
`ro,norecovery`). Only a separate scratch directory was bound over guest `/tmp`.
No existing/shared mount was changed; the private mount and loop were released.
No apk invocation, image write, Simulator interaction or candidate staging was
performed. The user still owns staging into the lifecycle candidate.

Verified runtime versions: **GLib 2.88.3, Pango 1.57.1, private GTK 4.22.4**.
Explicit `dlopen(RTLD_NOW | RTLD_GLOBAL)` succeeded for the frozen GtkSourceView,
commit shim and the image's actual `libspelling-1.so.2` (0.4.10). The guest musl
loader resolved all non-private dependencies inside that chroot; `loader.log`
records their paths. Frozen hashes match the table below exactly.

Passed with this closure: real text/deletion/selection/undo/redo/committed UTF-8
and decomposed-character buffer checks, C highlighting using the image's own
language data, seven-byte stream restoration, disabled/enabled tracing and
standalone SourceView roots. The callback forwarding/lifetime fixture also
passed with the commit shim preloaded, and its five spelling-labelled events
were verified. Loading actual libspelling does not by itself test dictionary
behavior; callback semantics are covered by the separate fixture.

Builder evidence and parsed per-edit logs:
`pinecone-builder:/tmp/pinecone-insertion-guest-abi-v2/`.
Host evidence archive:
`/tmp/pinecone-text-insertion-agent/artifacts-v2/guest-abi-evidence.tar.gz`.
Reproduce without rebuilding the frozen libraries:

```sh
limactl shell pinecone-builder sh \
  /Users/gmoran/Documents/Projects/arm64viz/scripts/text-insertion/test-guest-abi.sh \
  /tmp/pinecone-gtk-abi.ext4 \
  /tmp/pinecone-insertion-sourceview-v2 \
  /tmp/pinecone-insertion-guest-abi-next
```

This deliberately checks the existing v2 test binaries/fixture and exact runtime
versions; it is not a generic image tester. It compiles only a tiny dlopen/version
checker. The first harness attempt used absent `/usr/bin/env`; the successful
run uses the image's `/bin/busybox env`. No library rebuild was needed.

Files changed for this gate: added `scripts/text-insertion/test-load.c` and
`scripts/text-insertion/test-guest-abi.sh`; updated this report and the external
artifact `HANDOFF.txt`. Nine existing host regressions remain green. Remaining
risks/gates are actual editor/UI/IME/persistence behavior, native-vs-emulated
execution, and identifying the 4.76-second inner stage from the user's complete
`PCEDIT1` capture. These native functional checks provide no stall attribution
or performance-fix claim. No capabilities, persistence or input events changed.

## First-Edit Stall Follow-Up: Ready for User Staging

The corrected private GTK capture supersedes the initial workload below:
restoration of seven bytes took **5862.60 ms**, first typed `q` **4760.47 ms**
(a prior run was 4764.13 ms), and subsequent ordinary insertions had a 42.27 ms
median. These are guest wall-clock insertion intervals, not CPU attribution.
The new evidence requires capturing restoration and preserving per-edit detail,
not another overall median or a speculative spelling/title toggle.

**Built artifacts, frozen for the user's lifecycle-fix staging:**

Host directory: `/tmp/pinecone-text-insertion-agent/artifacts-v2/`

| File | SHA-256 |
| --- | --- |
| `libgtksourceview-5.so.0` | `0b3db7ec919293436c618ede1e96816002cdf58f2b3d6eedf888be999fa28761` |
| `libpinecone-text-trace.so` | `823e32b1af69c1731a8a46f2b609f42965a4f402443b46978479fe94102b1ced` |
| `libpinecone-text-commit.so` | `79c39bece733804fcb31ada1cca8f6061c0ebdc518481360dd3293cacfbe1f3b` |

**No rebuilt editor executable is needed for this route.** The stock editor
calls the instrumented GtkSourceView parent. Sourceview roots include loading
and normal insertions/deletions; an optionally instrumented editor remains the
outer root if present. The editor patch generator also now includes loading
and document/page cursor callbacks. The earlier non-loading-only capture design
below is historical, not the current behavior.

The existing build-only `pinecone-builder` instance contains:

- Source: `/tmp/pinecone-insertion-sourceview-v2/gtksourceview-5.20.0/`
- Build: `/tmp/pinecone-insertion-sourceview-v2/build/`
- Library: `build/gtksourceview/libgtksourceview-5.so.0.0.0` under that work directory.
- Tracer libraries/header: `/tmp/pinecone-insertion-sourceview-v2/runtime/`
- Generated source patch: `/tmp/pinecone-insertion-sourceview-v2/sourceview-trace.patch`
- Regression logs: `buffer-test3/` and `commit-test/` under that work directory.
- Original verified archive: `/tmp/pinecone-insertion-gtksourceview-5.20.0.tar.xz`

Host original source trees and archives remain in
`/tmp/pinecone-text-insertion-agent/`, including Text Editor 50.1 and libspelling
0.4.10. At the initial build, full editor compilation was blocked on absent
GtkSourceView, libadwaita, libspelling and editorconfig development packages;
this task installed no packages. The standalone sourceview route avoids this
requirement, regardless of subsequent package transactions owned by main.

### Rebuild and Launch Handoff

To reproduce into a **new** isolated build-only directory (two jobs by default):

```sh
limactl shell pinecone-builder sh \
  /Users/gmoran/Documents/Projects/arm64viz/scripts/text-insertion/build-sourceview.sh \
  /tmp/pinecone-insertion-sourceview-next \
  /tmp/pinecone-insertion-gtksourceview-5.20.0.tar.xz
```

The script verifies Alpine's SHA-512, rejects unexpected source bytes, builds
only GtkSourceView and two tiny tracers, and collects `artifacts/` plus checksums.
It does not install dependencies/packages, build GTK/Phosh, launch applications,
or modify any VM image. The first build stopped at upstream `-Werror=shadow`;
unique cleanup variable names fixed the tracer macro, and the incremental build
completed. Host regressions now also compile with `-Wshadow`.

For user-owned staging, put the three host libraries together, for example in
`/usr/local/lib/pinecone-insertion`, and add **only to the editor launch**:

```sh
PINECONE_TEXT_INSERTION_TRACE=1
LD_LIBRARY_PATH=/usr/local/lib/pinecone-insertion:${LD_LIBRARY_PATH:-}
LD_PRELOAD=/usr/local/lib/pinecone-insertion/libpinecone-text-commit.so${LD_PRELOAD:+:$LD_PRELOAD}
```

These assignments describe additions to the user's current diagnostic launch,
not a replacement launcher. Preserve its existing private GTK path, shared GTK
probe, Pixman preload, renderer and session variables. Do not export this to the
whole session or Phosh. Verify actual loaded paths and dependency resolution in
the target before restart. **The existing `pinecone-profile-exec` replaces
`LD_PRELOAD` from `PINECONE_GTK_PRELOAD`; `profile-gtk-guest.sh` sets that variable
itself. In the user's temporary diagnostic wrapper, append the commit shim to
the final `PINECONE_GTK_PRELOAD` assignment before calling the exec helper. An
outer `LD_PRELOAD` or earlier `PINECONE_GTK_PRELOAD` assignment is insufficient.**
The user's private editor wrapper also overwrites `LD_LIBRARY_PATH`; its final
value must include both the insertion and private GTK directories. No shared
wrapper or launcher was modified by this task.

The build used GTK 4.24.1, GLib 2.90.0, Pango 1.58.2,
GCC 15.2, `-O2 -g -fno-plt`, LTO and two compile jobs. Source is exactly 5.20.0,
but this is not a bit-identical Alpine rebuild. Subsequent headless buffer and
callback tests passed using a build-only copy of the existing private GTK
4.22.4 artifact (SHA-256
`3b9670c23d6306c69a994ec81f872e55b12fbea5844defa4f391cb0b2156f793`),
with `PC_TEXT_EXPECT_GTK=4.22.4` checking the loaded runtime version. Logs are
`private-gtk-buffer-test2/` and `private-gtk-commit-test/` under the build work
directory. That earlier check used the builder dependency set. The subsequent
guest dependency gate above now checks the image's complete dependency closure,
but not the editor UI. Do not use native timings as guest performance evidence.

No Simulator or runtime VM/disk was touched. In particular,
`/tmp/pinecone-agent-integration-20261031/lifecycle-candidate.ext4` remains
entirely user-owned and was not opened or modified by this task.

### What This Capture Resolves

`trace-commit.c` interposes the external public
`gtk_text_buffer_add_commit_notify` call and wraps only callbacks whose ELF
origin basename is `libspelling-1.so` or a versioned form. It does not inspect
opaque callback data, patch GTK, or rebuild/disable spelling. Before/after insert
and delete callbacks receive the original buffer, flags, character position,
character length and user data. GTK retains handler IDs/removal behavior;
the original destroy callback is forwarded exactly once. Closure allocation and
symbol/library-origin lookup happen at registration, not on each insertion.
No text is logged. Missing spelling labels mean **unobserved**, not zero cost.

The resulting per-root tree separates:

- `sourceview.gtk-parent.insert_text`, now with observed `spelling.commit.*`
  callback children when the shim is loaded.
- `gtk_source_buffer_content_inserted`, including cursor-moved signal work and
  bracket scheduling, and any synchronous highlight-engine insertions.
- The sourceview root versus the existing shared GTK handler interval. A large
  difference is still editor/signal work outside the sourceview virtual method;
  do not label that difference title-only. Stock editor title/session functions
  are not individually traced by the three-library deployment.

The analyzer now emits a complete `stages` tree for **each** `edit_roots` item,
including inclusive wall, guest thread CPU and wall outside direct traced
children. Use this, not aggregate medians, for restoration, first `q`, and warm
keys. Records are still buffered and emitted to stderr on **normal editor process
exit**, not SIGKILL. The user owns the known window-close/lifecycle issue; no
signal-handler, disk or session workaround was added here.

Concrete next input: return one complete `PCEDIT1` log covering the restored
seven bytes, first `q`, and a few warm keys, with the shared GTK trace unchanged.
If `spelling.commit.after-insert` dominates, the next exact path is
`spelling_engine_after_insert_text -> spelling_engine_invalidate` and its adapter
word-boundary/tag operations. If the GTK-parent residual dominates instead,
coordinate the GTK owner to split `gtk_text_history_text_inserted`,
`_gtk_text_btree_insert`, and changed/cursor notifications. If `cursor_moved`
dominates, trace its editor/page/position-label consumers. No branch is yet
proven dominant in the emulated guest, and none is removed/deferred speculatively.

### Follow-Up Verification and Changes

Passed on native aarch64 Linux using the isolated sourceview library:

- Real GtkSourceBuffer text, deletion, selection replacement, undo/redo,
  committed UTF-8/decomposed characters and enabled C highlighting.
- Real GtkSourceFileLoader restoration from a seven-byte memory stream,
  preserving its normal implicit terminal-newline convention.
- The same buffer checks with tracing disabled, enabled, and standalone
  sourceview roots (no editor/test outer scope needed).
- Commit-wrapper argument ordering, UTF-8 character count versus byte count,
  filtered flags, unrelated callback passthrough, removal IDs, data lifetimes
  and exactly-once destruction. The callback fixture has a libspelling-shaped
  DSO origin; it does not claim to test an actual dictionary or IME.
- Per-edit trace analysis and ELF dependency on one shared trace runtime.

The initial headless highlight test lacked an installed RelaxNG schema; the
test-only `PC_TEXT_LANGUAGE_PATH` selects the unpacked source data instead. No
runtime capability was disabled to make it pass. Nine host tests pass with the
source identity/inversion checks, loading/standalone-root guards, per-root
arithmetic and `-Wshadow` checks. Actual guest tracing, IME/persistence/UI checks
and an evidence-backed performance change remain pending user runtime results.

Files changed in this follow-up: `make-patch.py`, `trace.h`, `analyze.py`,
`test-trace.py`, `test-buffer.c`, `test-buffer.sh` under `scripts/text-insertion/`,
and this report. Added there: `build-sourceview.sh`, `trace-commit.c`,
`test-commit.c`, `test-commit.sh`. All other concurrent work was preserved.

## Decision

No performance change is justified yet. The measured insertion-handler median
is 76.96 ms of **guest wall time**, not 76.96 ms of editor CPU work. The
105.93 ms insertion-to-before-paint interval includes that handler; the
306.55 ms frame cycle and 416.88 ms insertion-to-after-paint overlap it as
described in `gtk-input-latency-profile.md`. Do not add these intervals or infer
CPU attribution from them. Disabling GTK4 animations did not help and is not a
speed fix.

This task adds opt-in, bounded source instrumentation, not a shipping package or
an optimization. No existing files outside this report and
`scripts/text-insertion/` were edited. No commit, Simulator/device interaction,
application installation, rootfs replacement/build, shared package build,
scheduler change, startup/cache change, or GTK/Cairo core patch was performed.
Two vCPUs, zero fallback, graphics correctness, persistence, input processing,
spelling, highlighting and editor capabilities remain required integration gates.

## Source Evidence

Read both requested profiles first. Local cached APK `.PKGINFO` identifies:

| Package | Version | Alpine aports commit |
| --- | --- | --- |
| gnome-text-editor | 50.1-r0 | 9fb728c019bf09e1c0eae6fa794fdb620c80bf08 |
| gtksourceview5 | 5.20.0-r1 | db954010a8a97398c595899d2870118d5886e440 |
| libspelling | 0.4.10-r0 | inspected for callback routing only |

These are cached guest packages, not a fresh query of the running guest APK
database. Before integration, confirm the target's versions and library/build
identity; do not assume a package filename proves the measured process loaded it.

Reproducible primary sources:

- [Text Editor Alpine recipe at the package commit](https://gitlab.alpinelinux.org/alpine/aports/-/blob/9fb728c019bf09e1c0eae6fa794fdb620c80bf08/community/gnome-text-editor/APKBUILD)
  uses the [50.1 tag archive](https://gitlab.gnome.org/GNOME/gnome-text-editor/-/archive/50.1/gnome-text-editor-50.1.tar.gz), with no downstream patches.
  Its SHA-512 was verified against the recipe:
  `2a2dbe8de9a32fb003efad9bd9715f4af663a0a153eb35b0cc36bccbdbce0678ba85dce0782c1234d9c4d95d7815aa57a6d01c7d7e92a30f310cef6ff2d4c90f`.
- [GtkSourceView Alpine recipe at the package commit](https://gitlab.alpinelinux.org/alpine/aports/-/blob/db954010a8a97398c595899d2870118d5886e440/community/gtksourceview5/APKBUILD)
  uses [5.20.0](https://download.gnome.org/sources/gtksourceview/5.20/gtksourceview-5.20.0.tar.xz), with no downstream patches.
  Verified SHA-512:
  `d0d25ab7098d6626bde49bbd5c29986838f0958cd3e31b5cab74016eb37a4caea3351be9ce4268464a8d1cb42b10b698aa819b215f652c8c97382e0900df7893`.
- [libspelling 0.4.10](https://download.gnome.org/sources/libspelling/0.4/libspelling-0.4.10.tar.xz)
  supplies the spelling callback definition; no libspelling source is patched.
- Read-only verification of [GTK 4.22.4 `gtktextbuffer.c`](https://github.com/GNOME/gtk/blob/4.22.4/gtk/gtktextbuffer.c#L1255)
  (matching the cached GTK package version) confirms commit callbacks surround
  `_gtk_text_btree_insert` inside `gtk_text_buffer_real_insert_text`. No GTK core
  file in this workspace was changed.

The patch generator pins SHA-256 identities of all five modified upstream files.
Text Editor's GNOME release tarball and Alpine tag archive have matching bytes
for all three instrumented editor files; the verified Alpine tag archive should be used for
package work. Both Alpine recipes enable LTO; preserve normal compiler options
for future instrumented/uninstrumented comparisons.

### Concrete Paths, Not Timing Claims

All line numbers below refer to unmodified upstream sources:

- `editor-document.c:429`, `editor_document_insert_text`: invokes the
  GtkSourceBuffer parent, then synchronously emits `notify::title` for unsaved
  documents when insertion offset is below 100 characters. Deletion at line 468
  has the corresponding notification. These are **not** unconditional title
  updates for saved files or every position. Do not throttle them without
  measuring the synchronous notification chain and preserving title semantics.
- `editor-page.c:226`, `editor_page_document_notify_title_cb`: forwards to page
  title notification, including bindings. `editor_document_dup_title` at line
  2201 scans a bounded prefix with Unicode classification. It does not scan the
  entire document. Source inspection does not establish expensive title work.
- `editor-document.c:358`, `editor_document_changed`: marks drafts for autosave
  and queues statistics reload when statistics exist. Session `changed` callback
  at `editor-session.c:738` calls `_editor_session_mark_dirty` (line 2471), which
  already returns when dirty. It schedules a timeout on transition; it does not
  synchronously save the session on every key. Persistence must not be removed.
- `gtksourcebuffer.c:1110`, `gtk_source_buffer_real_insert_text`: parent GTK
  insertion, then `gtk_source_buffer_content_inserted`, cursor-moved notification,
  bracket-update scheduling and, if present, highlight-engine text insertion.
  The delete counterpart is line 1194. Scheduled bracket work is not equivalent
  to synchronous bracket highlighting on every key.
- `editor_document_guess_content_type` runs on a first-line newline when not
  busy, and returns immediately if a language is already set. It is not a
  per-letter explanation for the measured `qwertyuiop` sample.
- `lib/spelling-text-buffer-adapter.c:104`,
  `spelling_text_buffer_adapter_commit_notify`: dispatches before/after insertion
  and deletion to the spelling engine. It is registered using
  `gtk_text_buffer_add_commit_notify`, not ordinary `insert-text` signal hooks.
  It is inside the unresolved GTK parent boundary. Merely placing extra
  before/after signal handlers cannot isolate its cost reliably.

## Diagnostic Design

`make-patch.py` emits unified patches for Text Editor or GtkSourceView without
modifying the supplied tree. It rejects changed source bytes and ambiguous
sites before emitting output. Both packages link **one shared trace runtime**;
do not compile separate copies of `trace.c` into them. The header uses compiler
cleanup scopes, including early returns, and statement wrappers execute the
original call once. No production condition or call is removed/reordered.

Only non-loading EditorDocument insert/delete virtual methods start capture
roots. Nested selected functions are recorded on the process loader/main thread.
Other threads and work outside a synchronous edit root are not captured. Roots
are buffer operations, **not keystroke, IME, document or shared-probe sequence
identities**; replacing a selection can have separate delete and insert roots.
Before/after signal handlers outside the virtual method and asynchronous
highlighting/spelling/autosave work are outside this scope.

Recorded boundaries include document changed/title/content-type functions,
the synchronous title-notify call, page notifications, session changed/dirty
callbacks, GtkSourceBuffer insertion/deletion, its GTK parent call, cursor and
bracket scheduling, and synchronous context-engine insertion/deletion/highlight
work. `sourceview.gtk-parent.insert_text` is deliberately a **mixed residual**:
GTK text storage, notifications, layout invalidation and libspelling commit
callbacks can all be inside it. Its time must not be labeled spelling-only.

The runtime records CLOCK_MONOTONIC and CLOCK_THREAD_CPUTIME_ID into a fixed
16,384-record array for at most 256 roots. No text, paths, object pointers,
allocation, file writes or timer scheduling occur in the instrumentation during
edits. At graceful process exit it writes fixed-label records to stderr. Crash,
SIGKILL and truncated output are not valid zero-latency captures. Start with a
fresh process and a short synthetic document. One array is roughly 1 MiB.

The analyzer rejects missing completion, dropped/limited records, invalid clocks,
duplicate identities, bad nesting and mismatched counts. It reports inclusive
wall and guest thread CPU separately, plus wall time outside **direct** traced
children. The latter is uninstrumented work plus overhead, not exclusive CPU.
Guest thread CPU is guest kernel accounting, not host CPU use; wall-minus-CPU
does not identify a scheduling/wait cause. Medians across nested labels must
not be added. Timestamp pairing with the shared probe requires same PID and
contained guest monotonic intervals, not equal sequence numbers.

## Package Handoff (User-Owned)

No package integration was run. In an isolated existing Linux build environment
with the matching development dependencies, the small runtime build is:

```sh
sh scripts/text-insertion/build-trace.sh /tmp/text-trace-runtime
python3 scripts/text-insertion/make-patch.py editor /path/to/gnome-text-editor-50.1 > /tmp/editor-trace.patch
python3 scripts/text-insertion/make-patch.py sourceview /path/to/gtksourceview-5.20.0 > /tmp/sourceview-trace.patch
```

Apply generated patches with `patch -p1` only to dedicated diagnostic source
copies, never shared builder trees. Pass the runtime directory as an include
directory (`pinecone-text-trace.h` is copied there) and link both targets with
`-L/path/to/runtime -lpinecone-text-trace`. Keep all existing Meson/Alpine options,
optimizations and dependencies; use diagnostic-only package revisions/prefixes.
Arrange one target-architecture `libpinecone-text-trace.so` in the runtime
library search path. Verify both ELF dependency lists and loaded library paths;
do not use the macOS test `.dylib` in the guest. No automatic download,
installation, rootfs edit or package promotion is in these scripts.

Optional buffer regression, after selecting the instrumented GtkSourceView
prefix via the normal pkg-config/runtime library paths and an available display:

```sh
sh scripts/text-insertion/test-buffer.sh /tmp/buffer-regression /tmp/text-trace-runtime
```

This exercises actual GtkSourceBuffer insertion, deletion, selection replacement,
undo/redo, committed UTF-8/decomposed characters, and enabled C highlighting with
tracing disabled and enabled. It refuses an unpatched GtkSourceView result.
It is **not** an EditorDocument persistence/title test or a real IME preedit test.
No display is started and no dependency is installed by this script.

## Exact Next Experiment

1. User integrates only diagnostic editor/sourceview packages and their shared
   runtime into the user's chosen disposable environment after verifying package
   identity. Keep normal settings, two vCPUs, graphics synchronization, language
   and spelling settings. Do not disable GTK4 animations as a performance fix.
2. Close an existing editor normally, then start a fresh diagnostic process with
   `PINECONE_TEXT_INSERTION_TRACE=1`, stderr captured to a new file, and the shared
   GTK latency probe unchanged. Leave protocol logging off. Use synthetic data.
3. Repeat the original ten isolated Squeekboard taps `qwertyuiop` in a fresh
   unsaved document. Close normally so records flush. Analyze using
   `python3 scripts/text-insertion/analyze.py /path/to/app.log`. Collect a
   disabled-trace control using the same binary to assess instrumentation cost;
   no timing comparison has been run by this agent.
4. Repeat in a saved plain-text document, then a language-enabled synthetic
   document with identical visible text. These are **attribution contexts**, not
   proof of a causal title/highlighting speedup; saved state changes other work.
   Use fresh processes, repeat in reverse order, avoid overlapping builds, and
   retain per-root records. Do not change spelling/persistence settings for speed.
5. If `document.title-notify` dominates, inspect its page-title/dup-title children
   and downstream bindings before proposing notification coalescing. If the
   context engine dominates, identify its measured synchronous function. If
   `sourceview.gtk-parent.insert_text` dominates after accounting for traced
   callbacks, the exact next unresolved branch is GTK's insertion body versus
   `spelling_text_buffer_adapter_commit_notify` and
   `spelling_engine_before_insert_text` / `spelling_engine_after_insert_text`.
   Coordinate per-function sampling or a libspelling callback scope with its
   owner; this agent deliberately did not patch GTK core or libspelling.
6. User verifies text/backspace, selection replacement and caret, non-ASCII IME
   preedit/commit/cancel, undo/redo, title/tab updates, spelling/highlighting,
   explicit save/reopen and autosaved draft recovery. Confirm zero fallback and
   correct rendering. No UI/integration gate is claimed passed here.

## Verification And Changed Files

Completed locally: nine focused Python/C tests, compiling tiny C fixtures with
`-std=c11 -O2 -Wall -Wextra -Werror`; shared runtime across a library boundary;
source-hash guards and exact inversion back to all five upstream source files;
analyzer nested-span arithmetic, incomplete/invalid/saturated rejection;
macro transparency for insertion/deletion/selection/UTF-8 payload operations
(a fixture, not GTK/IME coverage); enabled/disabled and foreign-thread behavior.
The standalone runtime builds on macOS. Shell syntax and generated-patch dry-run
checks pass; added-file whitespace checks report no errors.

Not run: Linux/aarch64 runtime or patched-package compile, optional GtkSourceBuffer
integration test, actual editor/IME/persistence regression, guest capture or
performance benchmark. This host lacks GTK4/GtkSourceView/libadwaita development
packages; none were installed. Full package builds need coordination, as requested.

Files added:

- `scripts/text-insertion/trace.h`: cleanup scope/call API.
- `scripts/text-insertion/trace.c`: bounded shared recording runtime.
- `scripts/text-insertion/build-trace.sh`: tiny standalone runtime build.
- `scripts/text-insertion/make-patch.py`: exact-source diagnostic patch generator.
- `scripts/text-insertion/analyze.py`: independent editor trace analyzer.
- `scripts/text-insertion/test-trace.py`: host runtime/source/analyzer regressions.
- `scripts/text-insertion/test-buffer.c`: optional real GtkSourceBuffer regression.
- `scripts/text-insertion/test-buffer.sh`: explicit Linux integration test driver.
- `docs/text-insertion-agent-report.md`: evidence, limits and handoff.

Risks: instrumentation perturbation (including disabled-call overhead), bounded
coverage, loss of logs on abnormal termination, ABI/build-version mismatch until
integration, and unmeasured asynchronous work. No measured handler component is
yet proven dominant, and no insertion-speed improvement is claimed. All
pre-existing dirty/untracked work was left intact; concurrent unrelated changes
were not reverted.
