import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_share.dart";

void main() {
  Uint8List zipOf(Map<String, String> files, {String? comment}) {
    final archive = Archive();
    files.forEach((name, text) => archive.add(ArchiveFile.string(name, text)));
    if (comment != null) archive.comment = comment;
    return ZipEncoder().encodeBytes(archive);
  }

  String payloadOf(String link) => Uri.parse(link).fragment;

  group("the link", () {
    test("carries the zip in the fragment, unpadded", () {
      final zip = zipOf({"a.txt": "hello"});
      final link = shareLinkOf(zip);

      expect(link, startsWith("https://$shareHost/#"));
      expect(payloadOf(link), isNot(contains("=")));
      expect(shareZipOf(payloadOf(link)), zip);
    });

    test("cut short anywhere reads as no zip", () {
      final payload = payloadOf(shareLinkOf(zipOf({"a.txt": "hello" * 50})));

      for (final cut in [1, 4, 17, payload.length ~/ 2]) {
        expect(
          shareZipOf(payload.substring(0, payload.length - cut)),
          isNull,
          reason: "cut $cut",
        );
      }
    });

    test("that is not base64 reads as no zip", () {
      expect(shareZipOf("not*base64!"), isNull);
      expect(shareZipOf(""), isNull);
    });

    test("whose bytes are not a zip reads as no zip", () {
      expect(shareZipOf(base64Url.encode(utf8.encode("hello world"))), isNull);
    });
  });

  group("zipEnds", () {
    test("finds the end record past a comment", () {
      expect(zipEnds(zipOf({"a": "b"}, comment: "a comment")), isTrue);
    });

    test("refuses a zip with bytes after its end", () {
      final zip = zipOf({"a": "b"});
      expect(zipEnds(Uint8List.fromList([...zip, 0])), isFalse);
    });
  });

  group("the ignore list", () {
    test("leaves out what is under a credentials or build folder", () {
      for (final path in [
        ".git/config",
        "app/node_modules/x/index.js",
        "home/.ssh/known_hosts",
        "rust/target/debug/app",
        "py/__pycache__/m.pyc",
      ]) {
        expect(isShareIgnored(path), isTrue, reason: path);
      }
    });

    test("leaves out a secret by its name, whatever its case", () {
      for (final path in [
        ".env",
        "api/.env.local",
        "id_ed25519.pub",
        "deploy/server.PEM",
        "Credentials.json",
        "infra/terraform.tfstate",
      ]) {
        expect(isShareIgnored(path), isTrue, reason: path);
      }
    });

    test("keeps ordinary files, and folders only named like a secret", () {
      for (final path in [
        "README.md",
        "src/main.dart",
        "build.gradle",
        "keys/notes.txt",
        "environment.md",
        "docs/dist.md",
      ]) {
        expect(isShareIgnored(path), isFalse, reason: path);
      }
    });
  });
}
