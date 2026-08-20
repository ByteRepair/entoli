# The Linux AppImage

`flutter build linux` produces a directory that has to move together — the
launcher resolves `lib/` through an `$ORIGIN/lib` rpath and finds `data/`
beside itself — and a release asset is one file someone runs. So the bundle
goes into the AppDir whole and unrearranged, under `usr/bin`, and `AppRun`
execs it where it lies. Anything lifted out of it is a file the app cannot
open.

**The packaging is `linux/packaging/make-appimage.sh`, not a step of the
workflow**, and it takes a bundle and an output path. It is the only genuinely
new thing in the release machinery, and left inside a YAML step the only way to
try a change to it would have been to push and dispatch. The action builds and
then calls it; `linux/packaging/` holds what it assembles — `AppRun` and the
desktop entry, named for the application id the way everything else on Linux
is. The icon it takes is `web/icons/Icon-512.png` and its file name comes from
the entry's own `Icon=`, so there is one authority for that string.

**Nothing of GTK is bundled.** The AppImage carries the Flutter engine and the
plugins and links against the system's GTK 3, exactly as the bundle already
did.

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
