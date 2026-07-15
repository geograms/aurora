# Validation — when a task is actually done

A task is **not** done when the code compiles. It is not done when the tests pass.
It is not done when the logic "should" work. It is done when it has been driven from
a user's finger on a connected Android phone and a screenshot proves the intended
result appeared on screen.

This document is the acceptance bar. It exists because the alternative — handing back
"implemented" and having the human discover it isn't — wastes the one thing that
doesn't scale: their patience and their time. Every round trip that ends in "it still
doesn't work" is a round trip that should have been caught here.

## The rule

> **No task is complete until it has been validated end-to-end on a real connected
> Android phone: actual taps on the actual UI, and a screenshot showing the feature
> working as the user would see it. From the user's perspective, not the code's.**

"From the user's perspective" is the whole point. A passing unit test verifies the
code does what the code says. A screenshot after a tap verifies the *user* gets what
the *task* asked for. Those are different claims, and only the second one is what was
requested. Code that is correct but unreachable (wrong screen, disabled button,
silent failure, never wired to the tap) passes the first and fails the second.

## What "validated" concretely means

For any UI-affecting change, before claiming done:

1. **Build a phone-installable, update-compatible APK** and install it on the
   connected device. Mind the two traps that make an install silently the *old*
   code (docs/performance.md §5):
   - Release-signed, not debug — a debug APK can't update a CI/release install
     (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`).
   - `--build-number` higher than what's installed, or
     `INSTALL_FAILED_VERSION_DOWNGRADE` leaves the old code running while the build
     "succeeded". **Verify the running versionCode after install** — do not assume.
   - Builds go through the machine lock: `~/bin/android-build-locked flutter build apk …`
     (never invoke `flutter`/`gradlew` build directly — see global instructions).
   - **The APK must bundle the wapp version you changed.** A host-only rebuild ships
     the *old* `assets/wapps/*.wapp` — your wapp fix isn't in the APK at all. Rebuild
     the `.wapp`, refresh the copy under `assets/wapps/`, then build the APK, and after
     launch confirm the running wapp version (its `/api/...` version line or the
     in-app version label) is the new one. An installed APK carrying a stale wapp is
     the single most common reason a "landed" fix appears not to have landed.
2. **Fully kill the old app, then launch — installing is NOT enough.** An install
   over a running app does **not** restart it: the *old* Geogram process keeps
   running the *old* code, and every tap you then make tests the version you thought
   you replaced. This is the trap that most often makes a real fix look like it
   didn't land — the AI concludes the change failed and re-does work that was already
   correct. So, every time, before touching the UI:
   ```sh
   adb shell am force-stop com.geogram.aurora
   adb shell pidof com.geogram.aurora        # MUST print nothing — if it prints a PID, kill again
   adb shell am start -n com.geogram.aurora/.MainActivity
   ```
   `force-stop` (not just closing the app, not just a back-swipe — those leave the
   foreground service and its process alive, §Device hygiene). Confirm `pidof` is
   empty *before* relaunching. Launch with `am start`, not `adb monkey` (it injects a
   random tap). Then give it time to settle before you start clicking.

   > **Rule: install → force-stop → confirm `pidof` empty → launch → verify version.
   > Skip any of these and you may be testing the old build and not know it.** If a
   > fix "didn't work", suspect a stale process or stale wapp *before* suspecting the
   > fix, and re-verify the running version first.
3. **Drive the real flow with real input.** Tap the buttons a user taps, type what a
   user types, navigate the screens a user navigates. `adb shell input tap/text/keyevent`
   or the equivalent. Exercise the path the task was about, from entry to result.
4. **Screenshot the result** (`adb exec-out screencap -p > shot.png`, then Read it)
   and confirm with your own eyes that the intended state is on screen — the new
   button is there and enabled, the message sent, the list updated, the badge
   cleared. A screenshot of the wrong screen is not validation; look at it.
5. **Cross-check the logs** for silent failure: `GET /api/log` (the in-app ring, no
   debug build needed). A UI that *looks* right while the log shows an exception is
   not validated.

Only after the screenshot shows the feature working do you say it's done — and say
so plainly, without hedging.

### Device hygiene (don't sabotage your own test)

- **Never `adb kill-server` / reconnect / reset transports on the test phones** — it
  forces a re-auth prompt on the device and stalls everything.
- **Measure/observe a clean process.** After API-driven start/stop cycles the app can
  leave a `DartWorker` pegged; `am force-stop` (confirm `pidof` prints nothing) before
  a fresh launch when behaviour looks off (docs/performance.md §4.1).
- **Do not reboot the test phone** to "fix" a state — you lose the state you were
  meant to validate.

## Status messages — keep the programmer un-blocked in their own head

A long build-install-drive-screenshot loop looks, from the outside, exactly like
being stuck. The programmer watching cannot tell "grinding through validation" from
"frozen" unless you tell them. So narrate.

> **Post a status message at each phase, and split any long operation so there is a
> heartbeat. Roughly every few minutes something should confirm forward motion.**

A good status says what phase you're in and what's next — "building release APK
(locked, ~4 min) → will install and drive the compose flow", "installed
versionCode 31102, launching", "tapped New Message, screenshotting", "screenshot
confirms the chip row renders; checking /api/log for send errors". The programmer
reads these and knows the work is progressing, not wedged. Silence during a
ten-minute build reads as a hang even when it isn't.

State implementation status honestly and specifically: what is built, what is
validated, what is still unverified, what is genuinely blocked (and on what). "Code
written, not yet validated on device" is a real and useful status — it tells the
programmer exactly where the work stands. Never report a not-yet-driven change as
working.

## Investigate the whole workflow, not the first bug

When validating a reported issue and you hit a bug: **fix it, then keep going.** Do
not stop, hand back, and wait. The single most expensive pattern is the serial
one-bug-per-round-trip: find bug A, report done, human re-tests, hits bug B, comes
back; fix B, report done, human re-tests, hits bug C. Each cycle costs a full
human-in-the-loop re-test, and it burns patience fast.

> **Walk the entire process end-to-end before declaring the workflow validated.**
> The first failure is rarely the only one. Continue past it — through every step of
> the flow, to completion — and surface *all* the blockers you find in one pass.

Concretely, when a flow is broken:

- After fixing the first blocker, **re-drive from the top** and continue through the
  remaining steps, even the ones you haven't reached yet.
- Assume more bugs lie downstream of the one that was hiding them. A crash on step 2
  was masking whatever step 3 does — you haven't tested step 3 at all yet.
- Report the whole chain: "fixed A and C, D is the next blocker and here's why",
  rather than "fixed A" and stopping. One thorough pass beats three shallow ones.
- The workflow is validated only when you have driven it all the way to the intended
  end result with a screenshot of that result — not when the first error stopped
  appearing.

Repeating the same build-drive loop three times to discover three bugs one at a time
is the waste this rule exists to prevent. Find them together.

## Why this is strict

The cost of a false "done" is not symmetric. Claiming done-when-not sends the human
off to re-test, hit the failure, context-switch back, and re-explain — minutes of
their attention for seconds you saved. Validating first costs you the build-drive
loop; skipping it costs them the loop *plus* the trust. Screenshot-verified, whole-
workflow, honestly-statused is slower per task and far faster per accepted task.
