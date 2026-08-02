# Working in this repo

## Running the Linux desktop app

**Automated GUI testing runs invisibly. Only put it on the user's screen when
the user has to look at it themselves.**

Driving the app with `xdotool` on the user's own display steals focus and types
into whatever they are doing. Use a private X server instead:

```sh
Xvfb :99 -screen 0 1400x900x24 &                            # once
DISPLAY=:99 ./build/linux/x64/release/bundle/aurora &        # the app
DISPLAY=:99 xdotool search --class radio.geogram.aurora      # find its window
DISPLAY=:99 xdotool mousemove --window <id> X Y click 1      # drive it
import -display :99 -window root shot.png                    # screenshot
```

Show it on the real display (`DISPLAY=:0`, no prefix) only when the user needs
to confirm something by eye, or asks to see it.

(`Xephyr :2 -screen 1400x900 -ac` is the middle ground: a nested server in a
window they can minimise. Xvfb is the default; Xephyr only if they want to peek
without giving up their focus.)

## Building

```sh
~/bin/android-build-locked flutter build linux --release     # desktop bundle
~/bin/android-build-locked ./launch-android.sh -- --build-number=<N>
```

Every heavy build goes through `~/bin/android-build-locked` (16GB machine; two
concurrent builds freeze it). Launch the **built bundle** directly rather than
`flutter run` — `flutter run` holds the build lock until the app quits, so a
queued APK build waits on it.

Android installs need `--build-number` above the installed `versionCode`
(`adb shell dumpsys package com.geogram.aurora | grep versionCode`), and other
sessions may be installing to the same phone.

## Wapps

Wapp source lives in `../wapps` (the `geograms/wapps` repo), not here;
`assets/wapps/*.wapp` are built copies. Ship chain:

```sh
cd ../wapps/<name> && WASI_SDK_PATH=~/wasi-sdk make          # -Werror
cd ../ && ./build-archive.sh <name>
cp binaries/<name>/<name>-<version>.wapp ../aurora/assets/wapps/<name>.wapp
```

Bump `manifest.json` version or installed copies never update.

## Debugging a wapp

`hal_log` from a **foreground page engine does not reach LogService**, so it
never shows in `/api/log` — only background-engine logs do. A wapp's own
`$type:"log"` panel (e.g. Mail's Status screen) is the reliable window into
what the page engine is doing.

The host logs every user-triggered command as `wapp <name>: cmd <command>`,
which distinguishes "the UI never sent it" from "the wapp ignored it".
