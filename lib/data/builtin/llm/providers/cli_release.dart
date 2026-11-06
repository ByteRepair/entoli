import "dart:io";
import "dart:isolate";

import "package:archive/archive_io.dart";

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
    required this.sha256,
    required this.packing,
    this.bytes,
  });

  /// Its file name in the CLI's folder, `.exe` and all.
  final String name;

  final Uri url;

  /// Lowercase hex, as the publisher states it. A file that hashes to
  /// anything else is not installed.
  final String sha256;

  final CliPacking packing;

  /// What the publisher says the file weighs; null leaves it to the
  /// response's own length.
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

  /// In an isolate of its own: a release is a hundred-odd megabytes to
  /// inflate, which the app's would otherwise stop drawing for.
  @override
  Future<void> place(File downloaded, String executable) async {
    final path = downloaded.path;
    await Isolate.run(() {
      final files = decode(File(path)).files.where((f) => f.isFile).toList();
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
