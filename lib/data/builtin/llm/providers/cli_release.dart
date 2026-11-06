import "dart:io";

import "package:archive/archive_io.dart";

/// One release of a CLI's program for this machine: where its file is, what
/// that file must hash to, and how the program is packed inside it.
class CliRelease {
  const CliRelease({
    required this.version,
    required this.url,
    required this.sha256,
    required this.packing,
    this.bytes,
  });

  final String version;
  final Uri url;

  /// Lowercase hex, as the publisher states it. A file that hashes to
  /// anything else is not installed.
  final String sha256;

  final CliPacking packing;

  /// What the publisher says the file weighs, for the bar; null leaves it to
  /// the response's own length.
  final int? bytes;
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

/// An archive holding the program as its one file, read in Dart so no
/// platform needs a `tar` or `unzip` of its own. What differs is the format.
abstract class ArchivedProgram extends CliPacking {
  const ArchivedProgram();

  Archive decode(File archive);

  @override
  Future<void> place(File downloaded, String executable) async {
    final files = decode(downloaded).files.where((f) => f.isFile).toList();
    if (files.length != 1) {
      throw FormatException(
        "expected one program in ${downloaded.path}, found ${files.length}",
      );
    }
    await File(executable).writeAsBytes(files.single.content);
    await downloaded.delete();
  }
}

/// A gzipped tarball.
class TarGzProgram extends ArchivedProgram {
  const TarGzProgram();

  @override
  Archive decode(File archive) => TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(archive.readAsBytesSync()),
  );
}

/// A zip.
class ZipProgram extends ArchivedProgram {
  const ZipProgram();

  @override
  Archive decode(File archive) =>
      ZipDecoder().decodeBytes(archive.readAsBytesSync());
}
