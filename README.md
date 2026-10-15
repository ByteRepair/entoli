# Entoli

ChatGPT-style chat UI with a coding agent behind it. Client-side: it calls your
own LLM endpoints and runs the agent's commands on your machine.

_Entoli_ (εντολή) is the Greek word for a command; both the one you give and the
one the agent runs.

![Entoli on Linux: a chat where the agent has finished an artifact, published
to the viewer](docs/screenshot.png)

## Obtaining Entoli

Entoli ships for Windows, Linux, macOS, Android, and the web.

**Windows**: download `entoli-installer.msi` from the
[GitHub releases](https://github.com/ByteRepair/entoli/releases) and run
it; its welcome page carries the licence and the Install button commits.
It installs to Program Files and puts Entoli in the Start menu. The build
is unsigned for now, so Smartscreen's More info, then Run anyway, is how the
installer's first run goes.

**Linux**: download `entoli-x86_64.AppImage` from the
[GitHub releases](https://github.com/ByteRepair/entoli/releases), make it
executable, and run it.

**macOS**: download `entoli-universal.dmg` from the
[GitHub releases](https://github.com/ByteRepair/entoli/releases), open it,
and drag the app to `/Applications`. The build is unsigned for now, so the
first open is Finder's right-click Open rather than a double-click.

**Android**: the app is distributed through Google Play closed testing.

1. Join the [Entoli Google group](https://groups.google.com/g/entoli).
2. Join the [closed test](https://play.google.com/apps/testing/io.byterepair.entoli).
3. Get the app from the
   [Google Play Store](https://play.google.com/store/apps/details?id=io.byterepair.entoli).

**Web**: the latest release is served at
[yiannis128.github.io/agent-chat](https://yiannis128.github.io/agent-chat/).

## Development

Entoli is a Flutter app targeting Windows, Linux, macOS, Android, and the
web. Beyond the Flutter SDK, each platform needs a few native dev libraries;
the lists below are the complete set, copy-pasteable into whichever package
manager you use.

### First, after cloning

```sh
tool/prepare.sh
```

Fetches the packages and generates the sources that `freezed` and
`json_serializable` produce, which are not in the repository — so **no Dart
target compiles until this has run**. Run it again after changing a `@freezed`
or `@JsonSerializable` type. The first run is about a minute; later ones are a
few seconds.

### Linux

GTK 3 and GStreamer dev headers (the latter come from `audioplayers_linux`),
plus the C/C++ build toolchain.

- Fedora: `clang cmake ninja-build pkg-config gtk3-devel gstreamer1-devel`
  `gstreamer1-plugins-base-devel`
- Ubuntu: `clang cmake ninja-build pkg-config libgtk-3-dev libgstreamer1.0-dev`
  `libgstreamer-plugins-base1.0-dev`

### macOS

Xcode and CocoaPods (`brew install cocoapods`). `flutter build macos` builds
the app; `tool/macos/make-dmg.sh` packages it — see `macos/AGENTS.md` for the
entitlements decision and what signing adds.

### Android

JDK 17 and the Android SDK with command-line tools. Gradle pulls the NDK it
needs; `minSdk` is 26.

#### Bundled tools

The APK ships a series of apps that are used for the agentic-dev. During
compilation, the compiler bundles everything in `android/app/src/main/jniLibs`.
This needs to be built, or else the agent will only have access to the default
shell utils included in Android (essentially Toybox).

`Entoli` ships the following builtin packages:

- `proot`
- `llama-server` (llama.cpp), which is what the On-device settings page runs

`git` used to be here, cross-compiled against bionic. It is not any more: the
agent gets git from `apk` inside the Alpine rootfs the Terminal settings page
installs, where a distribution patches it for a CVE rather than us. So on a
device with no rootfs installed there is no git.

Build them once per ABI, then stage them:

```sh
ANDROID_NDK_ROOT=$HOME/.android/ndk/<version> tool/android/build.sh arm64-v8a
tool/android/stage.sh
```

- `arm64-v8a` is what a phone wants; add `armeabi-v7a` and `x86_64` for
  emulators or a universal APK.
- The NDK has to be named explicitly; Gradle's own is not on `PATH`. Use
  `$HOME` rather than `~`: as an argument to `env` or inside quotes a tilde is
  not expanded, and the build fails on a path with a literal `~` in it.
- llama.cpp needs `cmake` and `ninja`, and is built for `arm64-v8a` only —
  `LLAMA_ABIS` overrides that. About 55 MB an ABI is why — the Vulkan backend's
  `libggml-vulkan.so` is 36 MB of it — and a 32-bit phone cannot map a model
  anyway, x86_64 Android being an emulator.
- The NPU wants Qualcomm's Hexagon SDK, and a build without it is a build
  without the NPU. `tool/android/setup.sh` fetches it into
  `tool/android/toolchains/`, checked against the SHA-256 pinned in
  `versions.sh`, and `build.sh` picks it up from there. Only the NPU is gated on
  it: the build always carries the CPU and the Vulkan GPU backend, so skipping
  the fetch still accelerates most phones, and the settings page says the device
  has no accelerator only when it has neither an NPU nor a Vulkan-1.1 GPU.
- CI runs all three steps from `.github/actions/bundled-tools`, the fetch
  included, so a release APK carries every backend. A release build whose arm64
  APK has no NPU libraries in it fails there: it is the only place a build that
  quietly lost them would be noticed.

Skipping this leaves an APK whose On-device page says it carries no model
server, and which cannot run a Linux at all.

#### Adding another precompiled tool

1. Pin the source in `tool/android/versions.sh`; version, URL and SHA-256. That
   file and the recipe are what the CI cache builds from.
2. Add a step to `tool/android/build.sh` that builds it against the NDK toolchain
   the script has already exported (`CC`, `AR`, `STRIP`, and a `CFLAGS` carrying
   API 26 and 16 KB page alignment), and strip the result into
   `$out/lib<name>.so`. Anything it links has to be built here too and linked
   statically: the guest is `bionic`, so glibc is not there, and the only
   libraries a device is guaranteed to have are `libc`, `libdl` and `libz`. The
   build checks this and fails naming what it finds, since otherwise the first
   thing to say so is the phone.
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

The cost is its size in every ABI the APK carries. And nothing on the device
updates any of this, so a CVE in a bundled tool is a version bump in
`versions.sh` and a release that every user has to install — which is the
reason git is no longer one of them, and worth weighing before adding another.

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

`tool/linux/make-appimage.sh` packages a `flutter build linux` bundle and
downloads `appimagetool` itself locally (pinned to a release, SHA-256 checked):

    tool/linux/make-appimage.sh build/linux/x64/release/bundle dist/entoli.AppImage
