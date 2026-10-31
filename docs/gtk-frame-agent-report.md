# GTK Frame Processing Investigation

## Decision and Evidence

No production performance change is justified by the available tap evidence.
The measured insertion handler (77 ms median), insertion-to-before-paint (106 ms,
including the handler), frame cycle (307 ms), and insertion-to-after-paint
(417 ms) are overlapping guest wall-clock intervals. They do not identify an
expensive GTK function or prove CPU rasterization, damage processing, or blocking
dominates. No repaint speedup is claimed. Disabling GTK4 animations remains a
rejected speed fix.

Read both existing profiles and the captured `animations-on.log` under
`/tmp/pinecone-gtk-latency-20261031/`. Its GTK mapping is
`libgtk-4.so.1.2200.4`; the cached package is `gtk4.0-4.22.4-r0.apk`.
Reviewed the corresponding upstream 4.22.4 sources:

- [gsk_renderer_render](https://github.com/GNOME/gtk/blob/4.22.4/gsk/gskrenderer.c)
  computes render-node damage, then calls the renderer.
- [gsk_cairo_renderer_render](https://github.com/GNOME/gtk/blob/4.22.4/gsk/gskcairorenderer.c)
  separates begin-frame, node drawing, and end-frame.
- [GskCairoNode](https://github.com/GNOME/gtk/blob/4.22.4/gsk/gskcaironode.c)
  creates a Cairo recording surface, not a fresh bitmap for pixel comparison.
- [gdk_texture_diff](https://github.com/GNOME/gtk/blob/4.22.4/gdk/gdktexture.c)
  unions known ancestor damage under a chain lock or marks full bounds. This
  path is not a bytewise image-difference loop.
- [Wayland Cairo begin/end-frame](https://github.com/GNOME/gtk/blob/4.22.4/gdk/wayland/gdkcairocontext-wayland.c)
  reuses a released SHM surface when available, expands accumulated damage,
  clears the repaint region, and later attaches/commits the surface.

The existing Cairo patch already scopes CPU access, checks fences, and preserves
escaping-pointer semantics. The Pixman bridge already has generation-aware
source/mask caches, packed A8 masks, committed SHM snapshots with damage updates,
exact snapshot allocation, and packed-row bulk copies. No duplicate cache/copy
policy, skipped clear, damage weakening, or fence removal was introduced.

## Diagnostic Changes

`PINECONE_GTK_LATENCY=1 PINECONE_GTK_FRAME_PROFILE=1` enables additional records
in the existing preload probe. Without the second flag, existing tracing remains
unchanged. Nothing installs or enables these diagnostics in production.

- Frame identity is the observed clock's frame counter, separate from insertion
  sequence. Record both insertion sequences at frame entry and exit; do not
  invent correspondence for an insertion arriving during a frame or idle frames.
- Emission hooks start update/layout/paint timers before already-connected GTK
  handlers. After-handlers stop them. Ordinary late-connected start handlers
  would miss the work being investigated. Handlers connected later using
  `G_CONNECT_AFTER` can still fall outside a phase's measured endpoint.
- Frame timing stops at after-paint emission entry. JSON formatting/output occurs
  in an after-handler, after the legacy after-paint record. New output is not
  included in either frame endpoint, but can perturb subsequent scheduling.
- Use guest `CLOCK_MONOTONIC` and `CLOCK_THREAD_CPUTIME_ID`. Thread accounting is
  not host CPU attribution. Wall minus thread accounting is **not** a measured
  blocking interval; host vCPU pacing/descheduling remains indistinguishable.
- Fixed-size TLS storage, at most four paint-bearing frames per insertion and
  512 records total (while insertion sequence is at most 256), at most 8192
  marks per frame. Invalid records also consume the bounded budget. Idle update
  ticks do not emit records or consume the budget. Overflow,
  missing clocks, and unbalanced scopes invalidate a frame instead of fabricating
  timings. No document contents or pixels are logged.
- Stages are inclusive. Nested stage times must not be added to paint/frame time.
  Reentrant calls within one stage count all calls but time only the outermost
  scope. The analyzer rejects malformed/truncated records, duplicate identities,
  missing stage fields, and inconsistent clocks. Unobserved stages are omitted
  from the summary, not reported as zero cost.

The optional `scripts/patches/gtk4-frame-profile.patch` adds weak private hooks
for `gsk_diff`, `cairo_begin`, `cairo_draw`, `cairo_end`, `texture_diff`, and
`texture_download`. These internal calls cannot reliably be intercepted through
public LD_PRELOAD symbols. With no hook provider, the source patch does nothing
apart from weak-symbol checks. It changes no rendering operations or arguments.
It is **not wired into any shared builder**. No full GTK compile was performed.

## Verification

Passed:

- `python3 scripts/test-gtk-latency.py`: 12 analyzer tests (the original five
  preserved, seven added).
- `bash scripts/run-gtk-frame-profile-regressions.sh` in the existing aarch64
  Linux builder: preload and launcher compile with `-Wall -Wextra -Werror`;
  normal and UBSan-trap headless fixtures pass. These exercise nested/repeated
  stages, invalid clocks, overflow, missing ends, emission-hook ordering, unchanged
  UTF-8 text and selection deletion, GSK/Cairo/Pango glyph pixels, partial clips,
  untouched pixels and row padding. Generated frame logs pass the analyzer.
- `python3 scripts/test-gtk-frame-patch.py GTK_SOURCE_DIR` in that builder:
  zero-fuzz/zero-offset patch application to upstream 4.22.4, all six mark pairs,
  original source equality after stripping diagnostic additions, and guest ELF
  weak-hook linkage with and without a provider.
- Shell syntax and diff whitespace checks.
- Existing `run-cairo-access-regressions.sh` against the already-built Pinecone
  Cairo overlay: lazy acquisition, balanced CPU scopes, flush, exports, mapping,
  finish, and caller-owned alias writes pass; patched and stock pixel hashes
  match (`b51c3ccfaaa9737b`). No Cairo library rebuild was needed.

The builder has GTK 4.24.1 and Cairo 1.18.4. The headless fixture therefore tests
probe/API compatibility and instrumentation neutrality there, **not** the full
patched 4.22.4 guest library. A preliminary macOS weak-link fixture failed because
Mach-O does not provide the same unresolved weak-symbol semantics; the test now
requires Linux, where it passed. No benchmark timings from the builder are used
as Pinecone performance evidence.

## Integration Handoff and Unresolved Paths

Copy `guest-gtk-frame-profile.h` alongside `guest-gtk-latency.c` when compiling
the existing probe as documented in the input profile. The existing wrapper
inherits `PINECONE_GTK_FRAME_PROFILE=1`; no wrapper/session edit is needed.
On unmodified GTK this immediately separates update/layout/paint, without a GTK
rebuild. Keep the normal Pixman preload and Cairo renderer policy unchanged.

For private GSK attribution, the integrator can apply the optional patch with
`patch --batch --fuzz=0 -p1 < /path/to/gtk4-frame-profile.patch` in an isolated
GTK 4.22.4 source tree, build it separately, and use the same preload. Private
stages missing from a capture do not prove their work was free or avoided.

Concrete unresolved paths and the next measurement:

1. `GdkFrameClock::layout` versus `::paint`: determine which accounts for the
   307 ms frame interval. Layout can include application widget work; this change
   does not modify Text Editor or GtkSourceView.
2. Within paint, `gsk_render_node_diff()` versus
   `gsk_render_node_draw_with_color_state()`. `texture_diff` identifies nested
   `gdk_texture_diff()` region/lock work, not a pixel-comparison cost.
3. `gdk_draw_context_begin_frame_full()` (including Wayland damage accumulation
   and clearing) versus `gdk_draw_context_end_frame_full()` (attach/commit).
   `texture_download` brackets `gdk_texture_download_surface()` within drawing.
4. If a measured stage has long wall time, collect matching guest thread stacks
   and wait/scheduling evidence during that stage before naming a blocking
   function or treating guest thread accounting as host CPU time. These probes
   do not themselves identify a futex, device fence, or scheduling dependency.

Repeat the same real Squeekboard tap sequence with identical instrumentation,
fresh documents, and reversed comparison order. User-owned integration must
check text, backspace, selection, non-ASCII composition, damage/stale pixels,
glyphs, and zero fallbacks with both vCPUs. No Simulator/device interaction,
rootfs replacement, app installation, shared image build, scheduler/model edit,
startup/session/cache edit, shared-report edit, or commit was performed here.
All pre-existing dirty and untracked work was retained.

## Integration: Exact GTK Library Build (2026-10-31)

The source-patched library has now been compiled separately from production.
`scripts/build-gtk-frame-diagnostic.sh NEW-WORK-DIRECTORY SOURCE-TARBALL`
requires Linux/aarch64 and verifies Alpine's pinned GTK 4.22.4 SHA-512 before
unpacking. It checks the patch, builds all normal runtime backends (including
Broadway, Wayland, X11, Vulkan, GStreamer and CUPS), but omits documentation,
introspection generation, demos and test programs. It never installs a shared
overlay or modifies the production rootfs. Alpine's null-handle patch for 32-bit
Vulkan builds is not needed for this aarch64 diagnostic.

Build environment: GCC 15.2, GLib 2.90.0, Pango 1.58.2, Cairo 1.18.4,
Graphene 1.10.8. Compiler flags were `-O2 -g -fno-plt`. This is the exact GTK
source version, not a bit-identical rebuild of the Alpine package; use matching
build flags and dependencies for any future performance A/B candidate.

Verification completed:

- Full library build and weak ELF hook linkage.
- A real `GskTextureNode` draw invokes the private texture-download hook once
  on entry and exit, preserving the exact four input pixels. The same fixture
  under stock GTK observes zero hooks and identical pixels.
- Existing accounting, signal, text, glyph, clip, damage and padding fixtures
  pass with this patched library, normally and under UBSan.
- The candidate guest's actual dependency set resolves the diagnostic library
  without missing-symbol errors in an isolated native chroot. Its Text Editor
  reports GTK 4.22.4. The real private-hook pixel fixture passes under both the
  stock and patched libraries in that same guest filesystem.
- The 12 host analyzer tests and shell syntax check pass.

The stripped diagnostic library SHA-256 is
`3b9670c23d6306c69a994ec81f872e55b12fbea5844defa4f391cb0b2156f793`.
Installed only in the validation VM at
`/usr/local/lib/pinecone-gtk-frame/libgtk-4.so.1`; the temporary Text Editor
launcher selects it with `LD_LIBRARY_PATH`. Phosh and every other application
continue using the original GTK. A fresh output directory is created for every
diagnostic launch. The ordinary guest image is unchanged.

Local artifacts: `/tmp/pinecone-agent-integration-20261031/`, including the
library, private launch scripts, `before-private-gtk.ext4` (pre-install backup),
and `private-gtk.ext4` (checked staging image). The user's six-character test
document was saved as `/root/qwerty.txt` before closing the editor and syncing
the disk. Journal recovery and filesystem checks ran only on the offline clone.
Native chroot checks alone are not an emulator performance result.

The first emulator run exposed a capture-budget defect: restoring the saved
document emitted an insertion before the manual typing, then update-only frame
clock ticks exhausted the original 512-frame budget. Private stages were present
for startup, but missing for the later keystrokes. Do not use that capture to
attribute typing cost. The diagnostic probe now emits only paint-bearing (or
invalid) records, limited to four per insertion and 512 total. Regression tests
exercise 1,000 idle ticks, rearming on a new insertion, invalid records, and the
global limits. Normal and UBSan fixtures pass after this correction. This is a
profiling fix, not a claimed production performance optimization.

## Corrected Simulator Capture

The validation VM booted into Phosh, unlocked by tap, and launched Text Editor
using the diagnostic library. Six real Squeekboard key taps appended `qwerty`
to the previously saved test text. Visual checks confirmed all six characters,
backspace deleting the last character, and newline moving the caret correctly.
No host text injection was used for the typing sample. Unicode composition and
selection were not retested in this run.

PID 506 produced 20 valid frame records with no invalid frames. Sequence 1 is
the seven-byte restored document, sequence 2 the first typed character, sequences
3-7 the five subsequent characters, and sequence 8 the newline check. The latter
five ordinary keys have these guest wall-time medians:

| Stage | Median |
| --- | ---: |
| Insertion handler | 42.27 ms |
| Insertion start to before-paint, including handler | 86.79 ms |
| Before-paint to after-paint | 165.21 ms |
| Insertion start to after-paint | 248.06 ms |
| Update | 57.10 ms |
| Layout | 46.02 ms |
| Paint | 69.08 ms |
| GSK node diff | 1.26 ms |
| Cairo begin-frame | 4.67 ms |
| Cairo draw | 42.58 ms |
| Cairo end-frame | 3.17 ms |

Frame stages select the first valid paint-bearing frame with an unchanged
matching sequence. This is temporal attribution, not proof of individual pixels
presented. The frame contains two Cairo render calls for these samples; their
aggregate is reported, not an assumed single-surface cost. No texture-diff or
texture-download calls occurred in those selected frames. Nested stages overlap;
separate medians must not be summed.

The first typed character is a separate outlier: **4,760.47 ms in insertion**,
9,023.84 ms until before-paint, and 9,282.63 ms until after-paint. Restoring the
seven-byte document also took 5,862.60 ms in its insertion callback. The earlier
private-stage run had a similar 4,764.13 ms first-edit insertion stall, although
its detailed frame budget had expired. These timings establish where to trace
next, not whether spelling, syntax, session notifications, loader work or guest
scheduling caused it. No particular function inside insertion is blamed yet.

The host's retained 115-frame sample had commit-to-present median 11.58 ms and
p95 23.92 ms, but is not individually paired to the keyboard sample. The visible
interpreter counter remained at zero fallbacks, and all paravirtual prepare,
finish, synchronization and native failure counters remained zero. Tests and
captures do not establish a production speedup: the library build, instrumentation,
document restoration, input spacing and cache state differ from earlier runs.

### Action Order

1. Integrate the version-matched Text Editor/GtkSourceView insertion tracer to
   split the reproducible first-edit stall. Include guest thread stacks/wait
   evidence before attributing it to CPU work or a specific synchronous service.
2. Split GTK update/layout work and Cairo draw by render-node type/operation;
   target repeated widget/layout work and the actual dominant draw operations.
   Keep damage, clipping, buffer ownership and fences intact.
3. Repeat an identical warmed and first-edit workload against an equivalently
   built baseline. GSK diff and begin/end-frame are low priorities in this typing
   capture; further optimizing those few milliseconds cannot remove the measured
   multi-second first-edit stall or all of the steady-state delay.

Raw evidence is `private-gtk-corrected-uart.log` and
`private-gtk-corrected-performance.json` under
`/tmp/pinecone-agent-integration-20261031/`. The prior budget-exhausted run is
`private-gtk-uart.log` and must not be used as a successful per-key capture.
The fixed probe SHA-256 is
`fbd3227e8e726a02a1108e35a3746e2dea216647d4731d87642e2e5e3ccaa040`.
The diagnostic image and pre-install backup are retained. Production library,
CPU execution settings, vCPU count, and the normal VM disk remain unchanged.

### Close-Window Failure: Acceptance Blocked

After the corrected typing capture and the normal Save Changes/Discard flow
for only the appended test characters, **Phosh exited with status 139**. Its log
reports `overview.c:277 (find_activity_by_toplevel): should not be reached` and
`on_toplevel_closed: assertion 'PHOSH_IS_ACTIVITY (activity)' failed`. Earlier
in the same session the Text Editor startup timed out and
`g_hash_table_remove_internal` reported a null table. These are concrete failure
signatures, not a proven root cause or evidence that the diagnostic GTK library
was loaded into Phosh. Only the editor selected that library.

The boot, unlock, typing, backspace and newline checks passed, but the complete
open/edit/close smoke test **failed**. No diagnostic library is promoted. The
trace remains useful for attribution; a stable equivalent workload and baseline
are still needed before accepting a performance fix. Restored the desktop's
normal `gnome-text-editor %U` launch path and disabled the diagnostic boot
script's desktop override before restarting Phosh. The library remains inert
in its separate directory for future investigation. Original saved text remains
at `/root/qwerty.txt`; only appended test edits were discarded.

Failure capture: `private-gtk-close-failure-uart.log` in the artifact directory.
Guest copies are `/tmp/phosh-private-close-failure.log` and
`/tmp/phoc-private-close-failure.log`. Isolate the Phosh activity/launch-timeout
lifecycle failure alongside the insertion investigation before promotion.

Recovery verification: restarted Phosh without the private editor override,
reached its lock screen, tapped through to the rendered Home screen, and left
that session running with zero fallbacks. The post-recovery open/edit/close
sequence was not repeated, so recovery does not establish that the window-close
bug is fixed or specific to the diagnostic build.

## Files Changed by This Task

- `scripts/guest-gtk-latency.c` (extended existing untracked probe)
- `scripts/analyze-gtk-latency.py` (extended existing untracked analyzer)
- `scripts/test-gtk-latency.py` (extended existing untracked tests)
- `scripts/guest-gtk-frame-profile.h` (new)
- `scripts/patches/gtk4-frame-profile.patch` (new, diagnostic only)
- `scripts/gtk-frame-profile-regression.c` (new)
- `scripts/run-gtk-frame-profile-regressions.sh` (new)
- `scripts/test-gtk-frame-patch.py` (new)
- `docs/gtk-frame-agent-report.md` (new)
