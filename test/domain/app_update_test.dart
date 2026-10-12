import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_update.dart";

void main() {
  group("versionIsNewer", () {
    test("a tag the running build is behind answers true", () {
      expect(versionIsNewer("1.2.3", "v1.2.4"), isTrue);
      expect(versionIsNewer("1.2.3", "1.3.0"), isTrue);
      expect(versionIsNewer("0.9.9", "1.0.0"), isTrue);
    });

    test("leading v and pre-release suffixes come off the release first", () {
      expect(versionIsNewer("1.10.0", "v1.11.0"), isTrue);
      // A suffix marks a pre-release: equal numbers are not an update, and
      // neither is running the same thing the tag names.
      expect(versionIsNewer("1.10.0", "1.10.0"), isFalse);
      expect(versionIsNewer("1.10.0", "v1.10.1-beta"), isTrue);
    });

    test("parts the release is missing count as zero, both ways", () {
      expect(versionIsNewer("1.2", "1.2.1"), isTrue);
      expect(versionIsNewer("1.2.1", "1.2"), isFalse);
      expect(versionIsNewer("1.2.3", "1.10"), isTrue);
    });

    test("numbers compare as numbers, never as strings", () {
      expect(versionIsNewer("1.9.0", "1.10.0"), isTrue);
      expect(versionIsNewer("1.10.0", "1.9.0"), isFalse);
    });

    test("a downgrade and an unreadable part are not updates", () {
      expect(versionIsNewer("1.2.3", "1.2.2"), isFalse);
      expect(versionIsNewer("1.2.3", "garbage"), isFalse);
      expect(versionIsNewer("garbage", "1.2.3"), isTrue);
    });
  });

  group("latestTagOf", () {
    test("the segment after the redirect's tag/ is the tag", () {
      final location = Uri.parse(
          "https://github.com/$updateRepo/releases/tag/v1.2.4");
      expect(latestTagOf(location), "v1.2.4");
    });

    test("nothing else on GitHub is a release", () {
      expect(
          latestTagOf(Uri.parse("https://github.com/$updateRepo/releases")),
          isNull);
      expect(latestTagOf(Uri.parse("https://github.com/$updateRepo")), isNull);
    });
  });

  test("the assets are named after the app, one name per platform", () {
    expect(assetFor(UpdateFlavour.linux), "entoli-x86_64.AppImage");
    expect(assetFor(UpdateFlavour.macos), "entoli-universal.dmg");
    expect(assetFor(UpdateFlavour.windows), "entoli-installer.msi");
  });

  test("a download URL puts the tag and the asset where a release puts them",
      () {
    expect(assetDownloadUrl("v1.2.4", appImageAsset),
        "https://github.com/$updateRepo/releases/download/v1.2.4/$appImageAsset");
  });

  test("the check asks the page's own latest-release URL, not the API", () {
    expect(latestReleaseUrl(),
        Uri.parse("https://github.com/$updateRepo/releases/latest"));
  });
}