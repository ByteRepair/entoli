# The Linux AppImage

`flutter build linux` produces a directory that has to move together — the
launcher resolves `lib/` through an `$ORIGIN/lib` rpath and finds `data/`
beside itself — and a release asset is one file someone runs. So the bundle
goes into the AppDir whole and unrearranged, under `usr/bin`, and `AppRun`
execs it where it lies. Anything lifted out of it is a file the app cannot
open.

**The packaging is `tool/linux/make-appimage.sh`, not a step of the
workflow**, and it takes a bundle and an output path. It is the only genuinely
new thing in the release machinery, and left inside a YAML step the only way to
try a change to it would have been to push and dispatch. The action builds and
then calls it; `tool/linux/` holds what it assembles — `AppRun` and the
desktop entry, named for the application id the way everything else on Linux
is. The icon it takes is `web/icons/Icon-512.png` and its file name comes from
the entry's own `Icon=`, so there is one authority for that string.

**`StartupWMClass=` is load-bearing.** GNOME matches a running window to a
desktop entry by id — application id on Wayland, WM_CLASS on X11, both the
application id here — never by `Name=`. Tools that install their own renamed
copy of the entry (Gear Lever writes `entoli.desktop`) break that match without
it, and the dock then shows the raw id under a generic icon; the field is what
lets any such copy claim the window.

**Nothing of GTK is bundled.** The AppImage carries the Flutter engine and the
plugins and links against the system's GTK 3, exactly as the bundle already
did. One native addition the bundle does carry, where it was staged:
**llama.cpp's server**, built by `tool/linux/build-llama.sh` into
`build/llama/` and installed by `linux/CMakeLists.txt` into the bundle's
`lib/` beside the engine — the same directory the launcher's rpath already
resolves, and the one place `platformLocalLlm` looks beside the executable. A
build that skipped the script ships without it, and the On-device page says
that rather than hiding the category. The app is built after the script runs,
so a bundle either carries the server whole or not at all.

**The session bus is a runtime dependency.** The reminders feature posts its
notifications over `org.freedesktop.Notifications` on it
(`lib/data/local/linux_reminder_alarms.dart`), and the sync keyring reaches
the Secret Service through the same bus. A session without a bus — headless, a
minimal window manager, the dev toolbox — leaves reminders saying so in the
settings page and the keyring on its file fallback; nothing crashes over it.

`appimagetool` is pinned to a release rather than tracking `continuous`, and to
a SHA-256 beside it: it builds the file the release is attested by, and a
release tag can be moved. It is run with `APPIMAGE_EXTRACT_AND_RUN=1` because
it is itself an AppImage and a CI runner has no FUSE to mount one with. The
runtime it embeds is static, so the AppImage it produces does not send anyone
looking for `libfuse2`.

The debug one is uploaded beside the bundle rather than instead of it, and is
`entoli-debug-x86_64.AppImage` with no version in the name: it is dispatched
from a branch rather than cut from a tag, so pubspec's version would name a
build nobody released.
