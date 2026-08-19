# Entoli

ChatGPT-style chat UI with a coding agent behind it. Client-side: it calls your
own LLM endpoints and runs the agent's commands on your machine.

*Entoli* (εντολή) is the Greek word for a command — both the one you give and the
one the agent runs.

## Development

Entoli is a Flutter app targeting Linux, Android, and the web. Beyond the
Flutter SDK, each platform needs a few native dev libraries; the lists below
are the complete set, copy-pasteable into whichever package manager you use.

### Linux

GTK 3 and GStreamer dev headers (the latter come from `audioplayers_linux`),
plus the C/C++ build toolchain.

Fedora: `clang cmake ninja-build pkg-config gtk3-devel gstreamer1-devel gstreamer1-plugins-base-devel`

Ubuntu: `clang cmake ninja-build pkg-config libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`

### Android

JDK 17 and the Android SDK with command-line tools. Gradle pulls the NDK it
needs; `minSdk` is 26. No native dev libraries on the host.

### Web

Only the Flutter SDK. No native dependencies — `sherpa_onnx`'s WebAssembly is
stubbed out via `dependency_overrides`, so it never enters the web bundle.

### AppImage

`linux/packaging/make-appimage.sh` packages a `flutter build linux` bundle and
downloads `appimagetool` itself (pinned to a release, SHA-256 checked), so no
extra host packages are needed beyond a working Linux build:

    linux/packaging/make-appimage.sh build/linux/x64/release/bundle dist/entoli.AppImage
