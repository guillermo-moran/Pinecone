# Lightweight Guest Lockscreen

## Scope

Phosh package `0.57.0-r8` provides a low-repaint mode in the existing guest
lockscreen. It is not an iOS overlay or a replacement authentication system.
The interpreter, CPU scheduling and graphics protocol are unchanged.

The mode defaults on with `PINECONE_PHOSH_LAUNCHER=1`. Set
`PINECONE_PHOSH_LIGHT_LOCKSCREEN=0` in the guest session environment before
starting Phosh to restore the previous carousel interaction. Explicit `1`
enables the lightweight mode independently of the launcher. These preferences
do not change Phosh's `require-unlock` setting.

## Rendering And Input

- A focusable, icon-labeled "Tap to unlock" button replaces the swipe hint.
  Clicking it requests the existing unlock page, where the existing PIN policy
  applies. It does not emit an unlock signal directly.
- Lightweight mode has no custom swipe recognizer. Taps outside the button
  and swipes do not initiate unlocking; the top panel keeps its own gestures.
- Carousel/deck and keypad-revealer transitions are instantaneous in this mode.
  Scoped CSS disables decorative animation/transition on lockscreen children.
- Notification rows are not bound, lockscreen plugins are not loaded, and media
  and notification panels are hidden. Incoming-call handling remains intact.
- Clock/date labels are updated only when their displayed text changes.

This reuses the existing GTK lockscreen tree, including the PIN page. It does
not eliminate every hidden widget's initialization or all Phosh background work.
The top panel is a separate surface and retains its existing gesture behavior.

## Home Preparation

Home's app model and widgets were already constructed before unlock. The new
path additionally warms GTK icon information at low idle priority, one icon per
dispatch, dock first, up to 32 icons. Cached references are retained by Home,
invalidated on model/theme/scale changes and released on disposal. Missing
icons are harmless. No duplicate Home framebuffer or hidden render loop is
allocated, and no surface visibility or input permissions change.

Set `PINECONE_PHOSH_HOME_PREWARM=0` before starting the guest session to disable
icon preloading for comparison. This is bounded best-effort preloading, not a
guarantee that every app asset is cached before the first unlock.

## Verification

- The original r7 package passed 45 Phosh test targets, including gesture threshold/direction/preferences,
  actual zero-duration HdyCarousel transitions with visible/hidden PIN pages,
  launcher layouts and disposal with a pending preload callback.
- 12 graphical overlay dependency tests pass; shell syntax and diff checks pass.
- The authentication completion, PIN submission, carousel page-change and
  lockscreen page-selection functions are byte-identical to the prior package.
  No new unlock emission or authentication-policy modification was added.
- Both upgraded guest images passed all five ext4 verification phases. Existing
  apps and user files were preserved; only Phosh and its platform pin changed.
- Simulator: shell at 3.96 seconds; Phosh readiness at 84.09 seconds in this
  run. Both prototype interpreter paths and two vCPUs remained enabled. Native
  execution stayed at zero fallback through Home, top-panel open, relock and
  another unlock. These startup measurements are not a controlled comparison.
- Original r7 UI checks: a 20-pixel upward pointer drag left the screen locked; a
  150-pixel upward drag unlocked to Home. The full-height accessibility swipe
  also unlocked. No user-assisted unlock was needed for these checks.

The static gesture removes the finger-follow animation, but a blank handoff
interval is still visible before Home appears. Unlocking before initial shell
startup finished produced a longer blank interval. Icon preloading does not
solve that compositor/session surface-readiness gap; it remains follow-up work.

Build log: `/tmp/pinecone-light-lockscreen-build.log`. This is not yet a controlled
before/after latency benchmark. The package build disables full Phoc integration
tests; these unit results do not constitute an end-to-end PIN authentication test.

## Tap-To-Unlock Follow-Up

Package r8 removes the r7 custom swipe code and replaces the hint with a standard
GTK button (200 by 52 logical pixels, 32-pixel bottom margin). Keyboard and
accessibility activation use the same button action. The existing unlock-page
selection, authentication completion and lock-manager code are unchanged. The
button test covers labeling, focusability, minimum dimensions and activation;
the zero-duration page-transition and preference tests remain in place.

The r8 rebuild passed all 45 Phosh targets and 12 packaging tests. Both upgraded
images passed all five ext4 verification phases. Build log:
`/tmp/pinecone-tap-lockscreen-build.log`.

Simulator r8 smoke test: an upward drag from below the clock to near the top
left the lockscreen visible. Clicking "Tap to unlock" then reached Home with
zero fallback instructions. The existing blank handoff interval remains. The
Simulator disk and bundled image are updated; installed apps and files remain.
