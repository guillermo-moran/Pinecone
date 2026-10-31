# Text Editor Literal Path Fix

## Cause

Text Editor 50.1 synchronously computes its subtitle when a document first
becomes modified. The path is:

```
GtkTextBuffer insertion -> changed -> modified-changed
-> EditorPage subtitle notification -> subtitle property binding
-> editor_page_dup_subtitle -> _editor_path_collapse
-> _editor_path_expand -> wordexp(g_shell_quote(path), WRDE_NOCMD)
```

Quoting the entire string makes the expansion return a literal path. On musl,
the unnecessary expansion still starts a shell. Guest syscall tracing showed
the editor's main thread waiting for the shell's `x\0/root\0` response.

The patch copies the literal string directly and retains the existing
relative-path-to-home behavior. It does not cache filenames, suppress subtitle
notifications, disable spelling, or change GTK editing and undo semantics.

## Measurement Correction

The first instrumented run measured a 4.5-second first insertion. That is not a
valid stock-performance baseline: diagnostic GTK and spelling preloads were
inherited by shell subprocesses, making them load the graphics dependency tree.
The syscall tracer also adds overhead. Neither run supports a production
speedup percentage.

The diagnostic launcher now tags its target PID. That target's probe constructor
removes only explicitly scoped diagnostic preload tokens from the environment
inherited by later child execs. The probes remain loaded in the editor;
production Pixman and unrelated preload tokens remain intact. The launcher and
probe must be installed together. Alternative probe locations require explicit
token configuration, not basename matching.

## Verification

- Direct original/patched path-helper comparisons cover null/empty paths,
  relative/absolute paths, quotes, whitespace, literal shell metacharacters,
  Unicode and non-UTF-8 bytes across three home-directory configurations.
- GTK buffer tests exercise insertion, deletion, selection replacement,
  undo/redo and committed Unicode with subtitle lookups in notifications.
- All 12 tests passed across native builder and exact guest-library runs.
  Patched path helpers import no process-launch or word-expansion APIs.
- The packaged executable passes the exact guest ABI check and both upstream
  desktop/AppStream metadata tests. These are not exhaustive UI tests.
- Normal validation-Simulator launch, document rendering, guest keyboard input,
  backspace, close/discard and return to Home passed with zero fallbacks.
- Diagnostic scoping passed host policy/exec tests and Linux real-loader tests,
  including retaining a non-diagnostic preload in both parent and child.

## Deployment

The reproducible package is `gnome-text-editor-50.1-r1.apk`; Phosh image staging
selects it by default. `PINECONE_USE_PATCHED_TEXT_EDITOR=0` retains the pinned
stock package for comparisons. The repaired executable and icon indexes are
installed in the disposable validation VM. The shipping rootfs and normal user
Simulator disk have not been rebuilt or replaced during this validation.

This removes a concrete synchronous subprocess cost, not all application launch,
keyboard, compositor or interpreter latency. End-to-end measurements must use
matched instrumentation and separately report the remaining work.

## Scoped Simulator Comparison

One sequential baseline/candidate pair, same running VM, generated icon caches,
private GTK/SourceView libraries, child-scoped probes and guest keyboard. No
strace ran during either sample. Both opened the same seven-byte saved document
and appended `qwe`; edits were discarded. Baseline PID 1144, candidate PID 1222.

| Guest monotonic interval | Baseline | Candidate |
| --- | ---: | ---: |
| First typed key handler | 398.468 ms | 94.912 ms |
| First typed key to GTK after-paint | 679.421 ms | 285.248 ms |
| Next key handler | 71.871 ms | 50.927 ms |
| Third key handler | 55.215 ms | 72.348 ms |
| Restored text insertion handler | 479.502 ms | 123.272 ms |
| Exec to first GTK after-paint | 31.113 s | 26.732 s |

This is an initial paired observation, not repeated/reverse-order statistics.
The candidate also had a faster pre-constructor interval, so do not attribute
the entire launch difference to this source patch. Warm-key results do not
establish a consistent improvement. GTK after-paint is not host presentation or
touch-to-screen latency; these guest wall-clock intervals are not host CPU time.

Evidence: `/tmp/pinecone-agent-integration-20261031/scoped-comparison-uart.log`.
For the GTK analyzer, select these two PIDs and deduplicate byte-identical
records echoed twice to UART. SourceView's complete traces independently show
first-key root spans of 395.46 ms and 92.14 ms with no dropped records. The same
Phosh PID 129 remained alive after both editor closes; fallback stayed zero,
saved file stayed seven bytes, and editor/strace processes exited.
