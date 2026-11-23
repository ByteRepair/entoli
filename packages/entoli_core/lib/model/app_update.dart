/// The release the app can update itself to from the three desktops, and the
/// pieces of the check every platform side shares. The platform half — where
/// a download is staged and what putting it in place means here — is
/// `core/platform/update.dart`; this file is what every side agrees on.
library;

import "dart:io" show HttpException;

import "package:http/http.dart" as http;

/// The repository the check looks at. `releases/latest` answers with a
/// redirect whose target names the newest release tag.
const updateRepo = "ByteRepair/entoli";

Uri latestReleaseUrl([String repo = updateRepo]) =>
    Uri.https("github.com", "/$repo/releases/latest");

/// The release assets, named after the app rather than the version — a
/// person is what downloads them and the tag is where a version lives — so
/// the same names serve every release. These are the names the app looks
/// for, and a release that renames one is a release the updater skips with
/// an error saying so.
const appImageAsset = "entoli-x86_64.AppImage";
const dmgAsset = "entoli-arm64.dmg";
const msiAsset = "entoli-installer.msi";

/// Which of the three desktops this build replaces itself as. The asset name
/// follows from it, and so does [available].
enum UpdateFlavour { linux, macos, windows }

/// The asset the release ships for [flavour].
String assetFor(UpdateFlavour flavour) => switch (flavour) {
  UpdateFlavour.linux => appImageAsset,
  UpdateFlavour.macos => dmgAsset,
  UpdateFlavour.windows => msiAsset,
};

/// Where a release tags [asset] can be fetched from.
String assetDownloadUrl(String tag, String asset) =>
    "https://github.com/$updateRepo/releases/download/$tag/$asset";

/// Whether [release] names a newer build than [current] does. Both are
/// dot-separated numbers; a leading `v`, a pre-release suffix and anything
/// after `-` or `+` are cut first, so a short part and a missing one both
/// count as zero. Equal is not newer, and neither is a parse that answers
/// nothing — an update never goes down.
bool versionIsNewer(String current, String release) {
  final a = versionParts(current);
  final b = versionParts(release);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final left = a.length > i ? a[i] : 0;
    final right = b.length > i ? b[i] : 0;
    if (left != right) return right > left;
  }
  return false;
}

/// The numbers one version string counts as. Leading digits per part, since a
/// part the parser cannot read is not a version this app shipped.
List<int> versionParts(String version) {
  final core = version
      .replaceFirst(RegExp("^v", caseSensitive: false), "")
      .split(RegExp("[-+]"))
      .first;
  return [for (final part in core.split(".")) int.tryParse(part) ?? 0];
}

/// The tag a `releases/latest` redirect points at, or null where it does not.
/// The segment after the path's `tag/` is the whole of what the check wants,
/// and GitHub puts it there — one segment, even where a stray `/` follows.
String? latestTagOf(Uri location) {
  const marker = "/tag/";
  final at = location.path.indexOf(marker);
  if (at < 0) return null;
  final segment = location.path.substring(at + marker.length).split("/").first;
  return Uri.decodeComponent(segment);
}

/// [repo]'s newest release tag, read off the redirect its `releases/latest`
/// page answers with — no API call, no rate limit, and the tag in the one
/// header GitHub has always put there.
Future<String> latestReleaseTag(
  http.Client client,
  String repo, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final request = http.Request("GET", latestReleaseUrl(repo))
    ..followRedirects = false
    ..maxRedirects = 0;
  final response = await client.send(request).timeout(timeout);
  try {
    if (response.statusCode >= 400) {
      throw HttpException(
        "${response.statusCode} for the latest release of $repo",
      );
    }
    final location = response.headers["location"];
    final tag = location == null ? null : latestTagOf(Uri.parse(location));
    if (tag == null) {
      throw FormatException(
        "the latest release of $repo points at $location, which names no "
        "tag",
      );
    }
    return tag;
  } finally {
    // A redirect's body is nothing, but a body nobody reads holds the
    // socket until the client is closed. A body that errors while it is
    // drained says nothing about the tag, which is already in hand.
    try {
      await response.stream.drain<void>();
    } catch (_) {}
  }
}

/// The platform half of the automatic update — see "The automatic update" in
/// the root notes. One side per desktop; the phones answer
/// [UnavailableAppUpdateHost].
abstract class AppUpdateHost {
  /// Whether this build is one the updater serves at all. The three desktops
  /// are; it is what takes the setting's row off the page everywhere else.
  bool get available;

  /// The whole startup check: the setting's answer and the running build's
  /// version in, nothing out but the log. Never throws — a network that is
  /// not there is the ordinary shape of a laptop waking up, and startup
  /// carried on while this ran.
  Future<void> check({required String? version, required bool enabled});
}

/// The answer on the platforms that do not update themselves: Android and
/// iOS, which reach releases through their own channels. Every
/// question is answered honestly and nothing runs.
class UnavailableAppUpdateHost implements AppUpdateHost {
  const UnavailableAppUpdateHost();

  @override
  bool get available => false;

  @override
  Future<void> check({required String? version, required bool enabled}) async {}
}
