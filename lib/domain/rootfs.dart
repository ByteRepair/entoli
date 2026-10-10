/// The Linux systems Entoli can put on a phone, as data. `rootfs_store.dart`
/// is what fetches one and `sandbox.dart` is what runs commands inside it.
///
/// A const list for the reason `voice_model.dart` is one: a distribution Entoli
/// can run is one someone checked the tarball of, so a new entry is a line here
/// rather than anything to discover. Sizes and checksums are exact, so the
/// settings page can say what a row costs before it is fetched and the download
/// can refuse a tarball that is not the one that was checked.
library;

/// One distribution's rootfs, per architecture.
class Rootfs {
  const Rootfs({
    required this.id,
    required this.name,
    required this.version,
    required this.packageManager,
    required this.images,
  });

  /// Stable, and the name of the directory it installs into — renaming one
  /// orphans what a user already downloaded.
  final String id;

  final String name;
  final String version;

  /// How the model installs something once it is in there. Named in the system
  /// prompt, since a whole Linux the model does not know it can add to is a
  /// distribution it will keep working around.
  final String packageManager;

  /// By Android ABI. An ABI that is not a key is one this distribution has no
  /// build for, which the settings page says rather than offering a download
  /// that cannot work.
  final Map<String, RootfsImage> images;

  RootfsImage? imageFor(String? abi) => abi == null ? null : images[abi];

  /// What the model is told it is on. The architecture is the guest's own name
  /// for it rather than Android's, since that is what `uname -m` in there will
  /// say.
  String describe(String? abi) {
    final arch = imageFor(abi)?.arch;
    return arch == null ? "$name $version" : "$name $version ($arch)";
  }
}

/// One architecture's tarball.
class RootfsImage {
  const RootfsImage({
    required this.arch,
    required this.url,
    required this.bytes,
    required this.sha256,
  });

  /// What the distribution calls this architecture — `aarch64` where Android
  /// says `arm64-v8a`. In the URL, and in what the model is told.
  final String arch;

  final String url;

  /// What the server will send, exactly. The bar reads it before the first byte
  /// arrives, and a `Content-Length` that disagrees is not treated as news.
  final int bytes;

  /// Checked before anything is unpacked. This is a filesystem full of programs
  /// that will then be run, so it is the one download in the app that is not
  /// merely trusted to have arrived — the same bargain `tool/android/versions.sh`
  /// makes for what is built into the APK.
  final String sha256;
}

/// **Alpine, and one version of it.** It is 4 MB against Debian's 120, it is an
/// official tarball rather than somebody's build of one, it is `.tar.gz` where
/// the alternatives are `.tar.xz` — which the system `tar` on a phone cannot
/// pipe and Dart decodes at a crawl — and `apk` is a package manager from the
/// first command. What it is not is glibc, so a binary someone downloads
/// prebuilt may refuse to run; that is the trade, and a second entry here is
/// what would answer it.
const alpine = Rootfs(
  id: "alpine",
  name: "Alpine Linux",
  version: "3.24.1",
  packageManager: "apk",
  images: {
    "arm64-v8a": RootfsImage(
      arch: "aarch64",
      url: "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/"
          "alpine-minirootfs-3.24.1-aarch64.tar.gz",
      bytes: 4023732,
      sha256: "f55a90f69052c5bd6f92cb09a8f47065970830b194c917a006fb94028e721259",
    ),
    "armeabi-v7a": RootfsImage(
      arch: "armv7",
      url: "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/armv7/"
          "alpine-minirootfs-3.24.1-armv7.tar.gz",
      bytes: 3176829,
      sha256: "50942d567e6ee422c16cb46d5c282ed9d8adc9007c2a483faf4148a18c64ce32",
    ),
    "x86_64": RootfsImage(
      arch: "x86_64",
      url: "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/"
          "alpine-minirootfs-3.24.1-x86_64.tar.gz",
      bytes: 3698422,
      sha256: "41f73e3cf5fa919b8aa5ca6b30dc48f0da2720776d7423e2a7748211456fe081",
    ),
    // iOS, keyed "ios" rather than by an Android ABI — iSH emulates x86 and
    // not the device's own arm64, so the guest is an i386 Alpine separate from
    // the arm64 one Android fetches. See ios/AGENTS.md.
    "ios": RootfsImage(
      arch: "i386",
      url: "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86/"
          "alpine-minirootfs-3.24.1-x86.tar.gz",
      bytes: 3538048,
      sha256:
          "634355e2245c9d56186d1b86fb6e034453eb303aea15b573ca250b343376fffd",
    ),
  },
);

const rootfsCatalog = [alpine];

Rootfs? rootfsById(String? id) {
  for (final entry in rootfsCatalog) {
    if (entry.id == id) return entry;
  }
  return null;
}
