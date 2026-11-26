import "dart:io";
import "dart:isolate";

import "package:archive/archive_io.dart";
import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;
import "package:entoli_core/agent/llm/providers/provider.dart";

/// One release of a CLI for this machine: the program, and any program it
/// runs beside itself, each a file of its own.
class CliRelease {
  const CliRelease({required this.files});

  /// The programs, the CLI's own last: it is the one whose presence says the
  /// copy is installed, so it is put in place after the rest.
  final List<CliFile> files;

  /// What they weigh together, for one bar; null where any is unstated.
  int? get bytes => files.any((f) => f.bytes == null)
      ? null
      : files.fold<int>(0, (sum, f) => sum + f.bytes!);
}

/// One program of a [CliRelease]: where its file is, what that file must
/// hash to, how the program is packed in it, and what it is called once
/// it is out.
class CliFile {
  const CliFile({
    required this.name,
    required this.url,
    required this.checksum,
    required this.packing,
    this.bytes,
  });

  /// Its file name in the CLI's folder, `.exe` and all.
  final String name;

  final Uri url;

  /// What the file must hash to. A file that hashes to anything else is not
  /// installed.
  final CliChecksum checksum;

  final CliPacking packing;

  /// What the publisher says the file weighs; null leaves it to the
  /// response's own length.
  final int? bytes;
}

/// A release on GitHub, by its API, which states each asset's SHA-256 as
/// its `digest`.
class GitHubRelease {
  GitHubRelease._(this._assets);

  /// The release [url] names: a repository's `releases/latest`.
  static Future<GitHubRelease> fetch(Uri url, http.Client client) async {
    final release = await LlmProvider.getJson(
      url,
      headers: const {"Accept": "application/vnd.github+json"},
      httpClient: client,
    );
    return GitHubRelease._(switch (release["assets"]) {
      final List<dynamic> assets => [
        ...assets.whereType<Map<String, dynamic>>(),
      ],
      _ => const [],
    });
  }

  final List<Map<String, dynamic>> _assets;

  /// The asset called [asset], installed as [name] out of [packing]; null
  /// where the release has none of that name.
  CliFile? file(
    String asset, {
    required String name,
    required CliPacking packing,
  }) {
    final found = _assets.where((a) => a["name"] == asset).firstOrNull;
    if (found == null) return null;
    final digest = found["digest"];
    if (digest is! String || !digest.startsWith("sha256:")) {
      throw FormatException("$asset has no SHA-256 stated beside it");
    }
    return CliFile(
      name: name,
      url: Uri.parse(found["browser_download_url"] as String),
      checksum: CliChecksum.sha256(digest.substring("sha256:".length)),
      packing: packing,
      bytes: found["size"] as int?,
    );
  }
}

/// A hash a publisher states beside a file, in the algorithm it chose.
class CliChecksum {
  const CliChecksum.sha256(String hex) : this._(sha256, hex);
  const CliChecksum.sha512(String hex) : this._(sha512, hex);
  const CliChecksum._(this.algorithm, this.hex);

  final Hash algorithm;

  /// As the publisher states it, either case.
  final String hex;

  bool matches(String digest) => digest == hex.toLowerCase();
}

/// How a release carries its program, and so how it is taken out.
sealed class CliPacking {
  const CliPacking();

  /// Puts the program [downloaded] carries at [executable].
  Future<void> place(File downloaded, String executable);
}

/// The file is the program.
class BareProgram extends CliPacking {
  const BareProgram();

  @override
  Future<void> place(File downloaded, String executable) async {
    await downloaded.rename(executable);
  }
}

/// An archive holding the program, read in Dart so no platform needs a
/// `tar` or `unzip` of its own: its one file, or the one named [member]
/// where it holds others beside it. What differs is the format.
abstract class ArchivedProgram extends CliPacking {
  const ArchivedProgram({this.member});

  final String? member;

  Archive decode(File archive);

  /// In an isolate of its own: a release is a hundred-odd megabytes to
  /// inflate, which the app's would otherwise stop drawing for.
  @override
  Future<void> place(File downloaded, String executable) async {
    final path = downloaded.path;
    final member = this.member;
    await Isolate.run(() {
      final files = decode(File(path)).files
          .where((f) => f.isFile)
          .where((f) => member == null || p.basename(f.name) == member)
          .toList();
      if (files.length != 1) {
        throw FormatException(
          "expected one program in $path, found ${files.length}",
        );
      }
      File(executable).writeAsBytesSync(files.single.content);
    });
    await downloaded.delete();
  }
}

/// A gzipped tarball.
class TarGzProgram extends ArchivedProgram {
  const TarGzProgram({super.member});

  @override
  Archive decode(File archive) => TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(archive.readAsBytesSync()),
  );
}

/// A zip.
class ZipProgram extends ArchivedProgram {
  const ZipProgram({super.member});

  @override
  Archive decode(File archive) =>
      ZipDecoder().decodeBytes(archive.readAsBytesSync());
}
