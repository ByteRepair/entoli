import "dart:typed_data";

/// Which files a chooser offers. Each platform filters on the field it knows —
/// extensions on the desktops, MIME types on Android, uniform type
/// identifiers on Apple's — so a filter names whichever apply. A [label] with
/// nothing else offers every file under that name.
class FileTypes {
  const FileTypes({
    required this.label,
    this.extensions = const [],
    this.mimeTypes = const [],
    this.uniformTypeIdentifiers = const [],
  });

  final String label;
  final List<String> extensions;
  final List<String> mimeTypes;
  final List<String> uniformTypeIdentifiers;
}

/// A file the user chose. [path] is a real file on every platform the app
/// runs on, Android's being a copy the chooser made under the cache, named
/// [name].
abstract interface class PickedFile {
  String get path;
  String get name;
  Future<Uint8List> readAsBytes();
}

/// Opens the platform's chooser for a folder or for files. Abstract so a page
/// that opens one can be driven in a test, where no plugin answers.
abstract interface class FilePicker {
  /// The folder the user chose, or null if they cancelled.
  Future<String?> folder({required String confirmLabel});

  /// The file the user chose, or null if they cancelled.
  Future<PickedFile?> file({String? confirmLabel, FileTypes? types});

  /// The files the user chose; none if they cancelled.
  Future<List<PickedFile>> files({String? confirmLabel, FileTypes? types});
}
