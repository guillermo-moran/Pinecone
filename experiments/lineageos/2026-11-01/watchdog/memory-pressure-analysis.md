# Android blank-UI stall: renderer versus memory pressure

## Conclusion

The `no-prewarm-1200s` capture does not support an llvmpipe JIT hang as the
primary failure. It supports whole-system memory/reclaim pressure overwhelming
`system_server` and delaying application startup and Surface transactions.
SurfaceFlinger remains runnable at modest CPU usage, while the app
`RenderThread` is nearly idle. Window transactions are delayed, but at least
one commits and finishes rather than hanging permanently.

The fastest controlled discriminator is to rerun the same no-prewarm system
candidate and the same userdata seed at 2 GiB:

- system image: `/private/tmp/pinecone-no-prewarm-system.raw`
- userdata seed: `/private/tmp/pinecone-no-prewarm-userdata.raw`
- change only guest RAM from 1 GiB to 2 GiB

Do not combine this test with another shader-cache or Mesa environment change.

## Evidence

All UART line numbers below refer to `no-prewarm-1200s.uart`.

At the first SystemUI ANR sample (`12:42:25.588` through `12:42:35.259`):

- `system_server`: 86% CPU (35% user, 51% kernel), line 8916
- SystemUI: 63% CPU, line 8917
- `media.swcodec`: 42% CPU, line 8918
- `crash_dump64`: 38% CPU, line 8919
- `kswapd0`: 15% CPU, line 8921
- SurfaceFlinger: 14% CPU, line 8922
- total CPU: 99%, including 51% kernel, line 8926
- I/O PSI `some avg10=12.55`, `full avg10=2.34`, lines 8909-8912

In the narrower second sample, SystemUI's `RenderThread` accounts for only
0.6% CPU (line 8951). SurfaceFlinger accounts for 5.9% (line 8964), while
`system_server` uses 74%, `media.swcodec` 65%, and `kswapd0` 21% (lines
8928, 8935, and 8943).

At the later provider ANR sample (`12:43:59.721` through `12:44:07.254`):

- CPU PSI `some avg10=73.94`, line 12145
- `system_server`: 198% CPU (97% user, 101% kernel), line 12154
- `kswapd0`: 23% CPU, line 12156
- SurfaceFlinger: 12% CPU, line 12158
- launcher: 7% CPU, line 12160

LMKD reports three low-watermark kills:

- permission controller, 139404 KiB RSS, line 9095
- device lock controller, 119564 KiB RSS, line 11435
- Lineage settings config, 115892 KiB RSS, line 11686

Window Manager reports transition #0's commit at 5121 ms and finish at 6614 ms
(line 8694). Later, SetupWizard starts at line 11058, its process starts at
line 11134, and `BluetoothSetupActivity` is created and launched at lines
11439 and 11457. These events show the UI pipeline progressing slowly rather
than stopping in one shader compilation.

The display snapshot nevertheless remains at generation 8 after 90 flushes,
88 unchanged. That is consistent with no useful composed buffer reaching the
scanout while application startup and transaction handling are overloaded; it
does not by itself locate a hang in llvmpipe.

The `android.ui` 60-second watchdog is likely secondary. ANR collection is
already active, `crash_dump64` consumes substantial CPU, debuggerd reports
timeouts, and the captured waiting channel for the `android.ui` thread is
`futex_wait_queue`, not an executing compiler thread.

## Mesa controls verified in this image

The actual Mesa driver was extracted from `/private/tmp/arm64viz-lp/vendor.img`
at `/lib64/libgallium_dri.so`. Its binary strings verify support for:

- `LP_NUM_THREADS`, `LP_NO_RAST`, `LP_NATIVE_VECTOR_WIDTH`, `LP_DEBUG`, `LP_PERF`
- `GALLIUM_DRIVER`, `GALLIUM_THREAD`, `GALLIUM_NOOP`
- `MESA_SHADER_CACHE_DISABLE`, `MESA_SHADER_CACHE_DIR`,
  `MESA_SHADER_CACHE_MAX_SIZE`, `MESA_SHADER_CACHE_SHOW_STATS`

These are available controls, not evidence that they will fix this capture.
In particular, disabling the shader cache or disabling SurfaceFlinger's eager
prime step can move more compilation onto first-frame paths. If the controlled
2 GiB run still fails, `LP_NUM_THREADS=1` versus the default is the smallest
useful llvmpipe scheduling experiment. `LP_NO_RAST=1` suppresses pixels and is
diagnostic only.

## Focused native-stack follow-up

Avoid another ActivityManager all-process native dump: it timed out and added
material load. If the 2 GiB run still stalls, add a one-shot init diagnostic
that captures only SurfaceFlinger and `system_server` after the stall is
observable:

```sh
debuggerd -b "$(pidof surfaceflinger)"
debuggerd -b "$(pidof system_server)"
```

Redirect the service's stdout and stderr to `/dev/kmsg` so the stacks reach the
UART capture even though the user build has no interactive shell. Trigger the
service once via a dedicated property or a bounded boot-relative delay. Do not
run it concurrently with watchdog bulk stack collection.
