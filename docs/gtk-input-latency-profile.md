# Text Editor Input and App Startup Profile

## Scope (2026-10-31)

Tested real taps on **guest Squeekboard in GNOME Text Editor**, not iOS keyboard
input or terminal echo. The test text was `qwertyuiop` in an empty disposable
document. All ten characters appeared in each of three captures. Both vCPUs
remained enabled, and the native execution counters reported zero fallbacks.
The normal iPhone 17 VM was stopped during measurement; its disk was preserved.

The host build includes the Simulator Metal barrier compatibility fix. The
standard guest image was unchanged (SHA-256
`ee5850fe31b77e5edad1519476460b8ed0cb2c82b57778d9b461520afc41bd9a`).
Only a cloned diagnostic disk received probes and experimental settings.

## Results

The corrected capture, with verbose Wayland logging **off**, measured these
guest CLOCK_MONOTONIC intervals for ten isolated keystrokes:

| Stage | Median | Range |
| --- | ---: | ---: |
| Text-buffer insertion handler | 76.96 ms | 41.91-93.66 ms |
| Insertion start to GTK before-paint | 105.93 ms | 73.79-131.54 ms |
| GTK before-paint to after-paint | 306.55 ms | 171.37-531.82 ms |
| Insertion start to GTK after-paint | 416.88 ms | 283.85-647.00 ms |

These intervals overlap; do not add all rows. Frame-cycle time includes GTK
update/layout/rendering, any blocking, and scheduling delays. It is **not** a
CPU-only rasterization measurement. GTK after-paint is not display presentation.

An earlier exploratory capture with Wayland protocol logging enabled measured
361.92 ms median insertion-to-after-paint (336.03-772.68 ms). Its host telemetry
reported 10.98 ms median / 23.79 ms p95 commit-to-display over the retained 256
frames, not specifically the ten text frames. This supports investigating work
before host presentation, but does not prove an exact per-key causal breakdown.
Do not subtract host timestamps from guest timestamps.

### Rejected Animation Experiment

The builder configures `gtk-enable-animations=false` for GTK 3 only. The probe
confirmed GTK 4 animations were enabled in Text Editor. Copying that setting to
GTK 4 in the disposable VM successfully disabled them, but did **not** establish
a typing improvement: the second ten-key sample measured 563.84 ms median
insertion-to-after-paint (356.55-997.64 ms), with 429.05 ms median frame-cycle time.

This was a sequential exploratory comparison, not a randomized repeated trial;
the second run also reused caches. It does not establish a causal regression
from the setting. It does reject promoting it as a demonstrated latency fix.
The experimental GTK 4 setting was not added to the shipping image or builder.

### Startup

The corrected Text Editor capture measured 23.68 seconds from exec to first
GTK after-paint: 3.27 seconds before the probe constructor, 0.22 seconds until
GApplication run, 9.14 seconds until its startup after-handler, then later window
construction and first-frame work. A constructor boundary includes dependency
loading, relocation and earlier constructors; it is not a pure loader timer.

An earlier exploratory Settings capture measured 26.03 seconds exec-to-first
after-paint, including 5.50 seconds before the constructor, 10.98 seconds from
GApplication run to startup after-handler, and 5.39 seconds from startup to
activate after-handler. Its helper initially preloaded GTK before exec and
Wayland logging was enabled. Discard its pre-exec constructor and do not use
launcher-tap-to-surface timestamps from that run: a failed setup launch preceded
the successful launch. These are diagnostic stage observations, not a claimed
shipping launch-time benchmark or speedup.

## Next Target

1. Sample Text Editor's main thread during the measured frame-cycle interval,
   distinguishing GtkSourceView/Pango layout, GSK Cairo drawing, buffer damage
   calculation, and blocking/scheduler time. Optimize the dominant measured path.
2. Trace GTK/GApplication initialization and service waits independently for cold
   Settings startup. Rendering/presentation tuning cannot remove work performed
   before the first window exists.
3. Repeat identical tap sequences with unchanged instrumentation and fresh
   documents, then reverse the A/B order. Validate rendered text, backspace,
   selection, and non-ASCII composition before promoting any input-path change.

Do not increase vCPU count or remove input/graphics synchronization based on
these measurements. This work adds diagnostic tooling; it does not claim to
have fixed keyboard latency or app launch speed.

## Reproduction

`scripts/guest-gtk-latency.c` is an optional GTK 4 LD_PRELOAD probe. Build inside
the existing Alpine/aarch64 builder (GTK development packages required):

```sh
cc -O2 -Wall -Wextra -Werror -fPIC -shared $(pkg-config --cflags gtk4) \
  guest-gtk-latency.c -ldl $(pkg-config --libs gtk4) -o libpinecone-gtk-latency.so
cc -O2 -Wall -Wextra -Werror -DPINECONE_PROFILE_LAUNCHER \
  guest-gtk-latency.c -o pinecone-profile-exec
```

Install into a **disposable** image at `/usr/local/lib/libpinecone-gtk-latency.so`
and `/usr/local/bin/pinecone-profile-exec`, with
`scripts/profile-gtk-guest.sh` at `/usr/local/bin/profile-gtk-guest.sh`. No
production build script installs these files. Start Phosh normally, close any
existing editor process, then run in the guest:

```sh
sh /usr/local/bin/profile-gtk-guest.sh editor /tmp/editor-sample &
```

Use `settings` instead of `editor` for the startup probe. The output directory
must be new. The wrapper preserves an allowlisted set of session variables and
loads the normal Pinecone Pixman bridge alongside the probe. The small exec
helper itself is not preloaded with GTK.

The probe records PID, monotonic time, insertion sequence and byte length, not
text. It observes the first application window and its currently present text
buffers; it is not a general multi-window or IME profiler. At most 256 insertions
are logged. A frame coalescing several insertions is paired only with the latest
sequence. Missing paint records must not be counted as zero latency.

`PINECONE_GTK_PROTOCOL_TRACE=1` optionally enables verbose Wayland logging, which
**can contain typed text**. Use only synthetic documents, never credentials or
private content. `PINECONE_GTK_DISABLE_ANIMATIONS=1` is a diagnostic-only override.
Normal profiling leaves both unset. All instrumentation has some overhead.

After guest `sync` and VM Stop, clone the diagnostic disk, replay its journal on
the clone, and extract the log. Never repair or edit the live mounted disk.
Analyze on the host:

```sh
python3 scripts/analyze-gtk-latency.py /path/to/app.log
python3 scripts/test-gtk-latency.py
```

Five analyzer regressions cover pre-exec constructors, coalesced insertions,
missing stages, invalid clocks/duplicate event identities, and frame-phase
separation. The aarch64 probe and launcher compile with `-Werror`.

Local raw captures: `/tmp/pinecone-gtk-latency-20261031/`, especially
`animations-on.log`, `animations-off.log`, `editor.log`, `settings.log`,
`repeat-uart.log` and the corresponding host metric JSON files. These temporary
artifacts and cloned images are not committed.

After testing, the diagnostic Simulator's original disk was restored. The normal
iPhone 17 session was relaunched without profiling overrides, reached Phosh,
and was tapped through to Home; its visible counter showed 2.784 billion native
instructions and zero fallbacks. No diagnostic settings were installed there.

## Four-Agent Integration Follow-Up (2026-10-31)

The four investigations are complete, but interaction acceptance and a matched
performance comparison are not complete. Two changes alter production behavior:

- Primary host duty-cycle pacing now waits on the existing wake generation
  instead of an uninterruptible sleep. Input arriving between the pacing decision
  and waiter registration cannot be lost. The requested delay remains capped at
  2 ms; this fix does not explain or eliminate the hundreds of milliseconds in
  the earlier GTK measurements. Continuation/timer overhead still needs runtime
  CPU and power comparison.
- Rootfs cache generation now runs the shipped ARM64 `gio-querymodules` against
  the shipped modules. The candidate ext4 contains registrations for dconf,
  GNOME proxy, GnuTLS, and libproxy. Its registry timestamp is newer than module
  ctime after image packaging. This restores normal lazy GIO module discovery;
  an application-launch speedup has not yet been measured.

The other two deliverables are diagnostic, not performance fixes. The GTK probe
can separate public update/layout/paint phases on the existing guest GTK. Private
GSK/Cairo stage attribution requires rebuilding GTK with the optional patch.
Text Editor/GtkSourceView insertion tracing likewise requires separately built,
version-matched guest libraries. Neither source-patched package is installed in
the candidate or the normal guest image. Do not interpret absent private stage
records as zero work.

Integration verification:

- 41 focused Swift application/interaction policy tests pass.
- 12 GTK latency analyzer, 12 graphical cache staging, and 5 native GIO tests pass.
- ARM64 headless GTK frame regressions pass normally and under UBSan. The
  builder GTK is 4.24.1, not the guest's 4.22.4; this is not exact guest-package
  integration coverage.
- Release iOS Simulator build succeeds; `git diff --check` passes.
- The candidate boots to shell and a visibly rendered Phosh lock screen, with
  zero interpreter fallbacks and zero reported paravirtual prepare, finish,
  synchronization, or native graphics failures in the inspected snapshot.
- Automated pointer injection fails with `windowNotFoundAtPosition` even though
  the Simulator is visible. Unlock, Settings launch, actual guest-keyboard typing,
  backspace, selection, composition, and input-to-frame measurements remain open.
  This is not a completed UI smoke test or a responsiveness acceptance result.

Artifacts are under `/tmp/pinecone-agent-integration-20261031/`. The clean
candidate is `rootfs.ext4` (SHA-256
`b751d02b1d49092ef7540961a663577f2cba33ce13f566e494dd6f397103ee65`).
The running validation VM uses a separate diagnostic clone with the preload
probe and profiled application launchers; verbose Wayland tracing is disabled.
Its original disk is backed up as `validation-original.ext4`. The normal iPhone
17 VM is stopped to avoid contention, with its app and disk preserved. The
standard bundled rootfs has not been replaced or promoted. Leave the validation
session available for the pending manual check, then sync/stop before extracting
logs from a disk clone; never repair a mounted guest disk.

### Diagnostic Launcher Correction

Manual verification exposed a harness error, not a missing package: the
temporary Text Editor desktop override used `/usr/bin/env`, which does not exist
in this guest. BusyBox provides `/bin/env`. GIO rejected the desktop entry's
nonexistent executable, so the launcher hid Text Editor. Corrected the running
guest's desktop override and profiling setup script to `/bin/env`; the local
setup source now checks that helper and the editor binary before modifying the
entry. The original production desktop entry was not affected.

After the correction, Home visibly lists Text Editor and 13 applications,
with zero interpreter fallbacks. The user successfully unlocked this session;
the actual guest-keyboard typing measurement remains pending. The normal VM
and clean candidate image were not modified by this diagnostic repair.

### User Typing Capture After Integration

The user reported essentially unchanged latency. Collected the instrumented
Text Editor log through the guest console after their test, without injecting
additional typing. PID 644 recorded six one-byte insertions and 512 valid frame
records. The probe does not record text, so this establishes six insertion
events, not independently verified document content or a complete editing test.

| Interval | Median |
| --- | ---: |
| Insertion handler | 23.62 ms |
| Insertion start to before-paint (includes handler) | 59.06 ms |
| Before-paint to after-paint | 282.64 ms |
| Insertion start to after-paint | 344.35 ms |
| First subsequent paint-bearing frame: update | 1.24 ms |
| First subsequent paint-bearing frame: layout | 37.29 ms |
| First subsequent paint-bearing frame: paint | 232.91 ms |

Insertion-to-after-paint spans 244.70-630.31 ms. The frame-stage rows select the
first valid paint-bearing frame with an unchanged matching insertion sequence;
they describe temporal context, not proof of the specific pixels presented.
Do not sum separate medians. Paint guest-thread accounting has a 167.71 ms
median, but is not host CPU time and cannot establish host scheduling delay.

Instrumented exec-to-first-after-paint was 20.38 seconds, including 2.77 seconds
before the constructor and 7.93 seconds from application-run to startup-end.
These results differ from the earlier capture in sample size, interaction,
instrumentation and cache state. Neither a percentage speedup nor a regression
can be attributed to the integrated changes from this comparison.

The contemporaneous host snapshot had 161 retained frame samples, with
commit-to-present median 11.27 ms and p95 25.05 ms. Those samples are not paired
to the six insertions. All four paravirtual failure counters were zero; the
visible interpreter counter also remained at zero fallbacks. Guest paint work
is the dominant observed typing phase, not the up-to-2-ms primary pacing delay.

Next: build the exact guest GTK 4.22.4 with the optional private-stage probe and
separate GSK diff, Cairo draw, and begin/end-frame costs before selecting a
rendering optimization. Public paint timing alone does not identify which of
those internals is responsible. Preserve damage, synchronization and text
correctness; repeat with identical instrumentation and reversed A/B order.

Raw capture: `/tmp/pinecone-agent-integration-20261031/editor-user-uart.log`;
host snapshot: `editor-user-performance.json` in the same directory. The
Simulator was returned to Display and left running. No responsiveness fix or
performance acceptance is claimed from this measurement.
