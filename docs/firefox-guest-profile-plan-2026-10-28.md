# Firefox Guest Profiling Plan

## Scope And Status

Investigation date: October 28, 2026 local; captured run crossed into October 29
UTC. This work is independent of native executor changes. Only new profiling
scripts/tests and this document are owned here. No guest disk, existing launcher,
preferences, native/Swift code, or Simulator UI was changed or exercised.
The manager owns all future guest execution and UI actions below.

No Gecko capture was available for this investigation. No function-level
main-thread attribution or speedup is established. The wrapper has offline
fixture coverage, not a successful live-guest profiling claim.

Evidence read:

- `docs/firefox-performance-profile-2026-10-28.md` and
  `docs/firefox-browser-2026-10-28.md`.
- `scripts/rootfs/pinecone-launch-firefox` and
  `scripts/rootfs/pinecone-firefox-user.js` (the repository's `user.js` seed).
- `/tmp/pinecone-firefox-profile-uart.log` and
  `/tmp/pinecone-firefox-profile-metrics.json`.
- Guest image/kernel build scripts and metadata/help strings streamed from the
  cached `artifacts/alpine-packages/edge-aarch64/firefox-151.0.3-r0.apk`.

## What The Evidence Supports

### Main Thread And Workload

The UART records launch at 01:41:37 UTC, guest uptime 167.17 s, parent PID 532.
At 01:43:50 its main-thread stat has 10523 user and 1164 system ticks; at
01:47:41 these are 19575 and 4219. Using the prior report's 100 ticks/s
conversion, total CPU grows from 116.87 to 237.94 s. Renderer grows from
1.67 to 2.60 s; `Softwar~cThread` from 1.93 to 22.29 s; `SwComposite` from
0.26 to 0.53 s. These are selected guest threads, not a browser-wide CPU split,
and sampling commands themselves take time. Record CLK_TCK explicitly next time.

The report's 220-second window-appearance figure is an upper bound from
intermittent screenshots. Main-thread CPU accounting does not distinguish
chrome JS, component initialization, session restoration, fonts, layout,
database work, graphics setup, system calls, or synchronization. Treat these
as candidate categories for profiling, not attributed hotspots. Host stacks
inside the emulator cannot name guest Gecko functions.

`about:blank` did not make this a clean-profile or offline test. The report
observed an additional `about:sessionrestore` tab, and the launcher always uses
`$HOME/.mozilla/pinecone`. The seed's `browser.startup.page=0` is not proof of
no crash recovery, no restored tabs, or no background network work. Seeding is
one-time: the actual persistent `user.js` and `prefs.js` were not inspected here.
The launcher does not overwrite an existing seed; do not assume installed
preferences equal the repository seed.

### Service And Startup Errors

- UART lines 154-158: elogind fails at guest uptime about 137 s, before Firefox.
  Lines 266-270 repeat failure at about 220 s, after Firefox launch. Both report
  missing paths while mounting tmpfs/cgroup under `/sys/fs/cgroup`, then manager
  allocation/daemon startup failure. `scripts/build-arm64-shell-kernel.sh`
  explicitly disables `CGROUPS` and checks that it remains disabled. Image
  staging installs elogind/polkit-elogind. Creating a directory alone is not a
  demonstrated fix for a kernel without cgroup support.
- Current image code handles optional UPower activation and feedbackd separately;
  it does not establish that elogind activation is disabled. The two failed
  attempts do not establish a continuous retry loop, the caller, a D-Bus timeout
  duration, or Firefox time lost. Do not transfer the image script's historical
  feedbackd 120-second timeout explanation to this Firefox run.
- `glxtest` shows 14 s cumulative CPU in the 01:42:07 process listing. This is
  worth isolating as graphics capability-probe work; it is not evidence of a
  GL failure or 14 s of exclusive critical-path delay. Later `at-spi-bus-launcher`
  and sandboxed glycin helpers are present. Presence alone does not prove stalls.
- Repeated `cat /tmp/firefox-profile.log` commands show no Firefox diagnostics
  in the UART. There is no captured portal, DNS, certificate, or Firefox sandbox
  error to assign as the cause. The failed smart-quote/`tr` shell command and
  unavailable `/proc/532/io` are diagnostic limitations, not Firefox failures.
- Parent `/proc/532/status` has `Seccomp: 0`. The integration report's content
  process `Seccomp: 2` was a separate observation. Parent status neither proves
  child sandbox failure nor proves all sandbox layers are effective. Preserve
  namespaces, seccomp, JavaScript, multiprocess operation, and site isolation.

Safe next service investigation: manager records `/proc/filesystems`,
`/proc/mounts`, `/proc/cgroups` if available, system/session D-Bus owner lists,
activation descriptors and elogind/session logs, without activating services as
a probe. In a separate diagnostic run, time and identify login1 activation
requests/replies and correlate them with Gecko markers/stacks. A later platform
fix should either supply the supported elogind/cgroup/session stack or explicitly
handle unavailable services in clients; evaluate polkit, seats, suspend and
sandbox behavior before changing service availability. No such fix is made here.

### Graphics And Memory

The seed requests software WebRender. SWGL is WebRender's CPU rasterizer, not
Pixman; its SIMD/span work remains guest CPU work.
[Mozilla SWGL implementation overview](https://github.com/mozilla-firefox/firefox/blob/main/gfx/wr/swgl/README.md).

The guest exposes 2D acceleration, not a guest GL/Vulkan driver (documented in
the seed). The `LD_PRELOAD` Pixman bridge and host Metal presentation do not
automatically accelerate SWGL, Gecko style/layout, display-list construction,
or JS. The `Software` thread's cost also means Renderer alone is not the entire
software graphics cost. Record actual `about:support` Graphics/decision-log
state after the measured interval, not during startup, and retain it with each
capture. Do not force hardware WebRender without a working guest graphics API.

Metrics are cumulative across boot/Phosh/Firefox: 127 frame samples, 12.97 ms
median / 30.23 ms p95 commit-to-present, 0.245 ms p95 commit-to-publish.
`firstVisibleFrame=4762.75 ms` is a boot milestone, not Firefox first paint.
Metal input/output copies total 2.341 s and GPU execution 1.042 s across the run;
these figures do not explain minutes of latency by themselves. They also do
not measure pre-commit guest work. Do not sum overlapping host phase counters.
`touchSampleCount=0`, empty interactions/attribution arrays and unavailable
input/frame identity prevent deriving exact input latency from this JSON.

Available memory ends at 729652 KiB (about 713 MiB); sampled swap, reclaim scanning,
allocation stalls and OOM counters are zero. This is not evidence for increasing
RAM as the first remedy, nor evidence about real-device headroom. Page faults
and cold reads can still matter without memory pressure; missing `/proc/PID/io`
does not establish zero I/O.

## Verified Capture Contract

Mozilla documents startup profiling via environment variables and normal-exit
capture using `MOZ_PROFILER_SHUTDOWN`. `MOZ_PROFILER_HELP=1 firefox` prints the
installed build's options and exits; use that instead of assuming UI presets
apply to startup.
[Official startup/shutdown guide](https://github.com/firefox-devtools/profiler/blob/main/docs-user/guide-startup-shutdown.md).

Implementation checks: entries bound a per-process circular buffer; interval is
milliseconds; duration limits retained sample age, **not** recording runtime.
Feature bitfields override feature names. Filters match thread-name substrings.
Normal shutdown saves parent data and retained exited-child profiles, not a
guaranteed live-child gather. Current SIGUSR2 handling uses a separate dump path;
do not assume it writes `MOZ_PROFILER_SHUTDOWN` or is a graceful browser quit.
[Mozilla profiler implementation](https://github.com/mozilla-firefox/firefox/blob/main/tools/profiler/core/platform.cpp)
(`PrintUsage`, `profiler_init`, `profiler_shutdown`,
`locked_profiler_save_profile_to_file`, `profiler_find_dump_path`).

These implementation links track upstream main, not the pinned Alpine build.
The cached APK reports version 151.0.3-r0, aarch64, Alpine packaging commit
`cdc35fe4aed02e61db73c38a51c7a04d9f382e71`; `application.ini` reports
BuildID `20260602093637`, source revision
`2d490a949ec649b79bfdecbc07b7531472dc41a0`. Its `libxul.so` contains the startup,
entries, duration, interval and feature help strings, including the retention
description. This supports capability discovery, not functioning unwind proof.
The exact release source was not retrievable in this environment. Confirm live
build metadata and help; do not infer signal behavior or symbol compatibility
solely from current upstream. Never send unverified signals to the guest.

For full multiprocess coverage, prefer the manager's normal profiler UI capture
while the workload is still present, then save locally. Child profiles appear
under `processes`; gathering can omit unresponsive children, so inspect the
actual process list and `profileGatheringLog` when present.
[Mozilla multiprocess profiler overview](https://firefox-source-docs.mozilla.org/tools/profiler/code-overview.html#multi-process-profiling).
Do not start a new recording from the UI after startup recording has begun.
Capturing/stopping in the UI may leave no later shutdown file; retain the UI
file and record this explicitly.

## Opt-In Wrapper

New `scripts/profile-firefox-guest.sh` is not installed or wired into normal
launches. A manager may stage it separately for an explicitly authorized guest
run. This investigation did not stage or execute it in the guest.

```sh
# Future guest commands, from the existing Phosh session, after a normal quit:
sh /path/to/profile-firefox-guest.sh --capture /tmp/firefox-main-01 about:blank

# Separate run, broader graphics threads and coarser sampling:
PINECONE_FIREFOX_PROFILE_MODE=graphics \
PINECONE_FIREFOX_PROFILE_INTERVAL_MS=20 \
sh /path/to/profile-firefox-guest.sh --capture /tmp/firefox-graphics-01 about:blank
```

The wrapper delegates all browser launch/security checks to the original
`pinecone-launch-firefox`. It requires an already seeded profile and the existing
Wayland/session-bus environment; it does not invent D-Bus addresses or preload
settings. No URL leaves the launcher's normal HTTPS default intact. Capture
uses `js,stackwalk,cpu`, main-thread-only filters by default (across processes).
No screenshots, allocation recording, verbose network logging, presymbolication,
remote-debugging server, new browser flags or preference writes are added.

Limits: default 1048576 entries, allowed maximum 4194304; intervals only
10/20/50 ms. These are diagnostic starting points, not tuned optima. Use the
live help's bytes-per-entry to compute nominal buffer memory (8/32 MiB at
8 bytes per entry). Total profiler/process memory and JSON size exceed this
budget, especially across children. The recording has **no automatic time
limit**. The manager must stop/capture promptly; a hard-kill watchdog would
risk losing the capture and contaminating session recovery, so none is supplied.

It refuses conflicting inherited profiler/log variables, known sandbox/process
disable variables, an existing Firefox process, invalid URLs/options and an
existing output directory. Directory creation uses mode 0700 under umask 077;
choose a trusted parent directory. The process-name check is conservative and
not race-free; the manager must serialize launches. It never deletes lock or
session files, kills processes, or cleans up evidence.

Artifacts: `profiler-help.txt`, `run.txt`, `firefox.log`, and on normal profiled
shutdown `shutdown.json`. The wrapper checks available features using installed
help, propagates launch failures and rejects missing/empty shutdown output.
Nonempty does not mean valid or complete. The preliminary help invocation warms
binary caches: label these runs accordingly, or perform the same help preflight
before unprofiled comparison runs. Do not label them cold launches.
Firefox itself still writes its normal persistent profile during a future run;
this wrapper is not a read-only browser mode.

## Manager Runbook And Acceptance

1. Freeze the emulator build/configuration, guest image, browser/bridge/kernel
   versions, viewport/scale, two-vCPU and 1 GiB settings. Record APK hashes and
   BuildID. Keep concurrent host builds/sampling out of timing comparisons.
2. Obtain a backup while Firefox is fully closed. Preserve the retained-profile
   case as evidence. For a separate clean baseline, the manager can prepare a
   disposable clone and normal-exit, single-blank-tab profile under a separate
   authorization. Do not delete recovery files or disable session restore in
   the original profile. Separate first-run, clean warm, and retained-session
   cases; do not compare them as the same workload. Inspect actual open tabs.
3. Record guest uptime and host monotonic/UTC timestamps, profile provenance,
   actual user.js/prefs.js hashes, startup cache/font cache state and network
   state. Capture process/tree and per-thread stat/status baselines, memory and
   vmstat. Use `busybox` applets where standalone tools are absent. Record raw
   `/proc/PID/task/TID/stat` fields and CLK_TCK if available; names can contain
   spaces, so parsers must split after the closing `)` rather than by whitespace
   from the start. Track PID/start-time pairs, including children that exit.
4. First capture startup through a visible blank window, then quit normally
   after a short idle period. A human stop target of roughly five minutes is
   reasonable given the previous upper bound, but is not an enforced timeout.
   Keep a separate run for address-bar focus, a fixed typing sequence and guest
   keyboard; a deterministic local page run for layout/paint/scroll; and an
   HTTPS navigation run for network/content. Record workload start/end and
   screenshots with bounds on observation latency. Do not combine all four
   into one long recording that overwrites startup samples.
5. Copy captures to the host through the manager's existing export mechanism
   after writing completes. Validate JSON with `python3 -m json.tool FILE`
   (redirect formatted output away from the terminal). Inspect parent and child
   `meta`, `threads`, `samples.schema/data`, stack/frame/string tables and
   library identities. Require nonempty GeckoMain samples with non-null stacks,
   correct recorded features/interval, and early samples covering the intended
   startup window. A file containing only markers, late samples, empty stacks
   or the wrong process is not successful main-thread attribution. Verify
   actual graphics-thread names before interpreting an absent filtered thread.
6. Inspect locally in the Firefox Profiler viewer; do not publish automatically.
   Check child/content tracks and missing-process warnings for each capture;
   absence of children is not absence of child CPU work. If startup rolled out,
   shorten the run or choose a coarser interval before increasing entries.
7. Collect unprofiled repeated trials separately, with identical preflight and
   profile provenance, to quantify instrumentation effects. Report at least
   three runs per condition, individual values and medians. Take host counter
   snapshots before/after each workload, not boot-to-end totals. Use symbolized
   stacks/markers to select a narrowly scoped future change, then verify it on
   blank startup, typing, local rendering and HTTPS with sandbox/isolation/JS
   unchanged. No performance claim until those measurements exist.

## Symbolication And Decision Gates

Alpine's `libxul.so` is not Mozilla's official binary. Retain exact aarch64 ELF
files, GNU build IDs, profile library `debugName`/`breakpadId`/`codeId`, package
hashes and matching debug packages on the host. Do not install debug packages
into the measured guest just to resolve symbols. A matching version label is
not enough: verify binary identifiers. Mozilla's symbol server may not have
this distribution build; missing native symbols remain an explicit limitation.
[Mozilla symbolication documentation](https://github.com/firefox-devtools/profiler/blob/main/docs-developer/symbolication.md).

For host-side local symbol serving, start with `samply load --help` and
`samply load FILE` using exact binaries/debug files in paths supported by that
installed version. Mozilla documents loading saved profiles with samply.
[Mozilla profiling guidance](https://firefox-source-docs.mozilla.org/testing/debugging-intermittents/index.html#use-the-firefox-profiler).
Verify resolved libxul native frames and stack depth in the viewer; merely
opening a profile or finding JS labels does not establish native symbolication.
No symbol bundle was found or tested here. Do not rebuild Firefox and treat its
new symbols as matching the old package. A later instrumented rebuild is a
separate experiment, not interchangeable performance evidence.

Profiles/logs can contain URLs, paths, typed text and page data. Retain locally;
symbol servers may receive library identifiers/addresses. Review before sharing.

Priorities for safe follow-up:

1. Establish uncontaminated workload labels and a usable GeckoMain capture.
2. Attribute startup categories only after validating symbols and sampled time
   coverage; measure font/JS/layout/I/O/cache/service hypotheses independently.
3. Investigate the demonstrated elogind/kernel mismatch, without disabling
   security services as a performance shortcut or assigning unmeasured delay.
4. Profile rendering separately, including software compositor and content
   threads. A guest GL/Vulkan acceleration path is platform work, not a
   preference toggle. Presentation-copy work cannot substitute for SWGL work.
5. Investigate the historical HTTP timeout in a separate network run only if
   reproduced. Mozilla's verbose HTTP logging is available but adds workload
   and sensitive data; keep it out of startup baselines.
   [Official HTTP logging procedure](https://firefox-source-docs.mozilla.org/networking/http/logging.html).

## Verification

- `sh -n scripts/profile-firefox-guest.sh`: pass.
- `python3 scripts/test-firefox-guest-profile.py`: 24 tests pass, all host-local
  fixtures; no browser, network, guest image, or Simulator execution.
- `python3 scripts/test-browser-packaging.py`: all 20 existing tests pass.
- ShellCheck was unavailable; shell syntax and fixture behavior were checked.
  No native/Swift tests were run for these new files.

Outstanding manager gate: an actual guest capture, process coverage validation,
matching-symbol resolution, and repeated workload timing. None is claimed done.
