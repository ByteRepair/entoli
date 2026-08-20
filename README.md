# Entoli

ChatGPT-style chat UI with a coding agent behind it. Client-side: it calls your
own LLM endpoints and runs the agent's commands on your machine.

_Entoli_ (εντολή) is the Greek word for a command; both the one you give and the
one the agent runs.

## Development

Entoli is a Flutter app targeting Linux, Android, and the web. Beyond the
Flutter SDK, each platform needs a few native dev libraries; the lists below are
the complete set, copy-pasteable into whichever package manager you use.

### Linux

GTK 3 and GStreamer dev headers (the latter come from `audioplayers_linux`),
plus the C/C++ build toolchain.

- Fedora: `clang cmake ninja-build pkg-config gtk3-devel gstreamer1-devel`
  `gstreamer1-plugins-base-devel`
- Ubuntu: `clang cmake ninja-build pkg-config libgtk-3-dev libgstreamer1.0-dev`
  `libgstreamer-plugins-base1.0-dev`

### Android

JDK 17 and the Android SDK with command-line tools. Gradle pulls the NDK it
needs; `minSdk` is 26.

#### Bundled tools

The APK ships a series of apps that are used for the agentic-dev. During
compilation, the compiler bundles everything in `android/app/src/main/jniLibs`.
This needs to be built, or else the agent will only have access to the default
shell utils included in Android (essentially Toybox).

`Entoli` ships the following builtin packages:

- `git`
- `proot`

Build them once per ABI, then stage them:

```sh
ANDROID_NDK_ROOT=~/.android/ndk/<version> tool/bundle/build.sh arm64-v8a
tool/bundle/stage.sh
```

`arm64-v8a` is what a phone wants; add `armeabi-v7a` and `x86_64` for emulators
or a universal APK. The NDK has to be named explicitly; Gradle's own is not on
`PATH`; and the host needs `make` and `perl` with `FindBin` (Fedora:
`perl-FindBin`), which OpenSSL's `Configure` uses. CI runs the same two steps
from `.github/actions/bundled-tools`, so a release APK always has git in it.

#### Adding another precompiled tool

1. Pin the source in `tool/bundle/versions.sh`; version, URL and SHA-256. That
   file and the recipe are what the CI cache builds from.
2. Add a step to `tool/bundle/build.sh` that builds it against the NDK toolchain
   the script has already exported (`CC`, `AR`, `STRIP`, and a `CFLAGS` carrying
   API 26 and 16 KB page alignment), and strip the result into
   `$out/lib<name>.so`. Anything it links has to be built here too and linked
   statically: the guest is `bionic`, so glibc is not there, and the only
   libraries a device is guaranteed to have are `libc`, `libdl` and `libz`.
3. Then `stage.sh`. It copies every `*.so` it finds per ABI.

The name matters twice. The installer extracts only `lib*.so` out of an APK, and
the native library directory is the one place an app may execute a file from, so
a binary named anything else is either not unpacked or not runnable. That is
also why `useLegacyPackaging` has to stay on in `android/app/build.gradle.kts`:
without it the file is mapped from inside the APK and there is nothing on disk
to exec.

Then tell the app. `BundledTools.install` in `lib/data/local/bundled_tools.dart`
symlinks the binary into its prefix under its real name; the link is what gives
it a name without a `lib` prefix, since the file itself may not be renamed; and
adds it to `Toolset.names`, which is what the system prompt tells the model is
there. Laying one out without naming it means a tool the model never reaches
for.

The cost is its size in every ABI the APK carries; git is about 12 MB each. And
nothing on the device updates any of this, so a CVE in a bundled tool is a
version bump in `versions.sh` and a release.

#### Adding a Linux distribution

On Android the agent can run its commands inside a downloaded rootfs under
proot, which is where a package manager comes from; nothing downloaded may be
executed directly, so the bundled tools are otherwise the whole of what a phone
can run. A distribution Entoli offers is a const entry in
`lib/domain/rootfs.dart` and a name in `rootfsCatalog`; nothing else has to be
told, because the Terminal settings category lists the catalog, downloads what
is picked, and the next command runs in it.

An entry names the distribution, its version, its package manager, and one image
per Android ABI. Each image carries the architecture under the guest's own name
for it (`aarch64` where Android says `arm64-v8a`), the URL, the exact byte count
and the SHA-256:

    curl -fLO <url>
    stat -c %s <file>; sha256sum <file>

Both numbers are load-bearing. The size is what the progress bar reads before
the first byte arrives, and the checksum is checked before anything is unpacked
— everything in that tarball becomes a program this device will run, which is
the same bargain `versions.sh` makes for what is built into the APK. An ABI left
out of `images` is one the settings page says has no build for it, rather than
offering a download that cannot work.

The tarball has to be `.tar.gz`: the system `tar` on a phone cannot pipe `.xz`
and Dart decodes it at a crawl. Prefer a small official rootfs with a package
manager working from the first command; `packageManager` is named in the system
prompt, so the model knows how to install what it needs. `id` is the directory
the rootfs installs into under the cache directory, so renaming one orphans what
a user already downloaded.

### Web

Only the Flutter SDK. No native dependencies; `sherpa_onnx`'s WebAssembly is
stubbed out via `dependency_overrides`, so it never enters the web bundle.

### AppImage

`linux/packaging/make-appimage.sh` packages a `flutter build linux` bundle and
downloads `appimagetool` itself locally (pinned to a release, SHA-256 checked):

    linux/packaging/make-appimage.sh build/linux/x64/release/bundle dist/entoli.AppImage
