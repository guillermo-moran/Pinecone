# Phosh Window Lifecycle Repair

## Observed Failure

The validation session exited with status 139 after closing Text Editor. Its log
contained a launch timeout, a null hash-table removal warning, then an overview
lookup failure for the closing toplevel. No unsupported ARM64 instruction was
reported. A subsequent stock-GTK editor open/close succeeded. The failure is
timing-sensitive; this does not establish that the diagnostic GTK library caused
it, nor does it identify a faulting instruction without a backtrace.

## Window Tracking Defects

The pinned Phosh 0.57.0 source and Pinecone patch stack contain these defects:

- `remove_from_launching()` returns when `app_id` is non-null. Consequently a
  correctly identified window does not retire its pending launch timeout.
- `app_info_has_toplevel()` compares a desktop-file ID directly with a Wayland
  app ID, although the latter commonly omits `.desktop` or uses an alias.
- The missing-window callback checks thumbnail availability rather than the
  actual toplevel association. Thumbnail delivery is asynchronous and a hidden
  overview need not have a thumbnail. A live window can lose its activity.
- The overview retains a raw selected-activity pointer when a splash is removed
  by a timeout. Clearing it only in the normal window-close path is insufficient.
- The initial-window timeout emits callbacks before retiring its borrowed launch
  record. Reentrant callbacks can remove that record while the timer uses it.

`phosh-pinecone-window-lifecycle.patch` repairs the state transitions, not the
assertions. It resolves desktop IDs through the existing Phosh resolver, retires
matching launch records (including repeated requests), retries on late app IDs,
uses window association for liveness, and clears selection/disconnects callbacks
when an activity is destroyed. An old startup failure cannot remove a newer
splash with a different startup ID. An empty pending-launch list exits before
desktop resolution so routine window configures do not add that work.

The timeout removes its record before notifying consumers, holding independent
references to the manager and app info throughout notification. Removal executes
even with `G_DISABLE_CHECKS` defined.

## Callback Ownership

`phosh-pinecone-tracker-ownership.patch` retires terminal launch records before
emitting application-ready/failed signals and retains independent notification
arguments. Async Flatpak replies carry a weak tracker reference plus cancellation
identity instead of a borrowed state pointer, so cancellation or startup-ID reuse
cannot make an old reply mutate a new launch. Launch-context signals are bound
to the tracker lifetime; the initial asynchronous bus acquisition owns its tracker.

Splash windows previously borrowed their startup IDs from hash-table keys. Table
removal freed those keys before a fading splash's close callback finished. Each
splash now owns its ID, and close removes only the table entry for that same
window. Tracker signal connections also disconnect when the splash manager is
disposed. These are independent ownership defects; no backtrace established which
one produced the original null-table warning.

## Verification Gates

The source-derived harness executes the patched production functions with real
GLib/GObject and thin window/widget fixtures. It is not a replacement for an
actual GTK/Wayland session test. Tests cover valid, absent and unknown app IDs,
aliases, duplicate launches, late configuration, reentrant timeout callbacks,
mapped windows without thumbnails, and destruction of selected activities.

The current window suite passes 17 cases with checks enabled and 17 disabled;
the tracker/splash suite passes 22 in each configuration. Both were run with
non-recovering UBSan. Original-source negative controls reproduce 10 window and
9 ownership defects. ASan has not been verified. The macOS window harness now
reports timeout as incomplete rather than counting a timeout as a negative
control success.

Before promoting a package: run those regressions with checks enabled and
disabled, compile the full guest package, validate its guest-library ABI, then
boot/unlock Phosh and repeatedly open, edit and close Text Editor. Preserve the
user's saved document and test new input in disposable documents.

This is a lifecycle correctness repair. It does not itself establish an
improvement to first-edit or warm-key latency; those need separate measurements.

## Validation Package

The complete r9 package passed 45 upstream tests and an ABI check against the
validation guest's libraries, including all 23 shell plugins. The executable
links its shell implementation directly; the separate libphosh package is not
a dependency of the executable or those plugins.

The r9 executable and plugins are installed in the disposable Graphics Mask
Validation Simulator. Boot, tap-to-unlock, a stock Text Editor open/edit/close,
and a private instrumented editor open/edit/close passed. Both close tests
returned to Home with the same Phosh process (PID 129), no new lifecycle
warnings, and zero interpreter fallbacks. Synthetic edits were discarded and
the saved seven-byte document was preserved. These are smoke tests, not proof
that every timing-sensitive crash is eliminated without the original backtrace.

The image staging default selects r9. The shipping rootfs and the user's normal
Simulator disk have not been replaced by this validation run. Private GTK and
insertion probes are not production overlays.

Subsequent normal and child-scoped diagnostic editor trials also returned to
Home without restarting Phosh. The validation VM was synced, stopped and
relaunched after testing; persistent root mounted, the repaired editor hash
survived, and Phosh reached its lock screen with zero fallbacks. No editor or
strace diagnostic process was started on that final boot.
