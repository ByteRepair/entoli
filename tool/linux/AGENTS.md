# The Linux AppImage

`flutter build linux` produces a directory that has to move together — the
launcher resolves `lib/` through an `$ORIGIN/lib` rpath and finds `data/`
beside itself — and a release asset is one file someone runs. So the bundle
goes into the AppDir whole, under `usr/bin`, and `AppRun` execs it where it
lies; anything lifted out is a file the app cannot open.

**The packaging is `tool/linux/make-appimage.sh`, not a workflow step**, and
it takes a bundle and an output path: the only way to try a change to the
packaging without pushing and dispatching. `tool/linux/` holds what the
script assembles — `AppRun` and the desktop entry, named for the application
id the way everything else on Linux is. The icon comes from
`web/icons/Icon-512.png`, its file name decided by the entry's own `Icon=`,
so one string is the authority for it.

**`StartupWMClass=` is load-bearing.** GNOME matches a running window to a
desktop entry by id — application id on Wayland, WM_CLASS on X11, both the
application id here — never by `Name=`. Tools that install their own renamed
copy of the entry (Gear Lever writes `entoli.desktop`) break the match
without it, and the dock shows the raw id under a generic icon; the field is
what lets any such copy claim the window.

**Nothing of GTK is bundled.** The AppImage carries the Flutter engine and
plugins and links the system's GTK 3, exactly as the bundle already did. The
one native addition is **llama.cpp's server**, built by
`tool/linux/build-llama.sh` into `build/llama/` and installed by
`linux/CMakeLists.txt` into the bundle's `lib/` beside the engine — the
directory the rpath already resolves, and the one place `createLocalEngine`
looks beside the executable. The app is built after the script runs, so the
bundle carries the server whole or not at all; a build that skipped it ships
without it, and the On-device page says so.

**A release build is one instance per session.** A second launch registers
the same application id on the session bus, finds the first, activates it —
which raises its window — and exits, rather than running a second session
over the same data directory (two trigger managers, settings written over
each other). A debug build stays non-unique: its data directory is its own,
and it must run beside an installed copy.

**The session bus is a runtime dependency.** Reminders post over
`org.freedesktop.Notifications`, and the sync keyring reaches the Secret
Service through the same bus. A session without a bus — headless, a minimal
window manager, the dev toolbox — leaves reminders saying so in the settings
page and the keyring on its file fallback; nothing crashes over it.

`appimagetool` is pinned to a release rather than tracking `continuous`,
with a SHA-256 beside it: it builds the file a release tag is attested by,
and a tag can be moved. It runs with `APPIMAGE_EXTRACT_AND_RUN=1` because it
is itself an AppImage and a CI runner has no FUSE to mount one with; its
embedded runtime is static, so the AppImage produced sends nobody looking
for `libfuse2`.

The debug build is uploaded beside the bundle, as
`entoli-debug-x86_64.AppImage` — `debug` standing where the release name has
nothing, and no version in either: it is dispatched from a branch rather
than cut from a tag, so pubspec's version would name a build nobody
released.

The updater knows this asset by name and updates itself through it: the
download is renamed over the file `$APPIMAGE` names, so the release artifact
and the thing a running Entoli executes are one file and the update is one
rename — the next launch runs what was downloaded. A Linux not running from an
AppImage has nothing under `$APPIMAGE` to point the rename at; the check says
so in a line and moves on. See "The automatic update" in the root notes.