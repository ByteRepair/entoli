import "dart:typed_data";

import "package:file_selector/file_selector.dart";
import "package:entoli_core/model/attachment_picker.dart";
import "package:entoli_core/model/file_picker.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/mime.dart";

/// The platform's own file chooser, through `file_selector` — one plugin
/// covering every platform the app runs on.
class FileSelectorPicker implements AttachmentPicker {
  const FileSelectorPicker();

  static const _images = XTypeGroup(
    label: "Images",
    extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "avif"],
    mimeTypes: [
      "image/png",
      "image/jpeg",
      "image/gif",
      "image/webp",
      "image/bmp",
    ],
    uniformTypeIdentifiers: ["public.image"],
  );

  @override
  Future<List<Attachment>> pick(AttachmentKind kind) async {
    final files = await openFiles(
      acceptedTypeGroups: switch (kind) {
        AttachmentKind.image => const [_images],
        AttachmentKind.file => const <XTypeGroup>[],
      },
    );
    return Future.wait(files.map(_read));
  }

  Future<Attachment> _read(XFile file) async {
    final bytes = await file.readAsBytes();
    return Attachment(
      filename: file.name,
      mimeType: attachmentMime(file.name, bytes, declared: file.mimeType),
      bytes: bytes,
    );
  }
}

/// The platform's own folder and file choosers, through the same plugin.
class FileSelectorFilePicker implements FilePicker {
  const FileSelectorFilePicker();

  @override
  Future<String?> folder({required String confirmLabel}) =>
      getDirectoryPath(confirmButtonText: confirmLabel);

  @override
  Future<PickedFile?> file({String? confirmLabel, FileTypes? types}) async {
    final file = await openFile(
      confirmButtonText: confirmLabel,
      acceptedTypeGroups: typeGroups(types),
    );
    return file == null ? null : _Picked(file);
  }

  @override
  Future<List<PickedFile>> files({
    String? confirmLabel,
    FileTypes? types,
  }) async => [
    for (final file in await openFiles(
      confirmButtonText: confirmLabel,
      acceptedTypeGroups: typeGroups(types),
    ))
      _Picked(file),
  ];
}

/// [types] as the plugin's filter; null offers every file.
List<XTypeGroup> typeGroups(FileTypes? types) => [
  if (types != null)
    XTypeGroup(
      label: types.label,
      extensions: types.extensions,
      mimeTypes: types.mimeTypes,
      uniformTypeIdentifiers: types.uniformTypeIdentifiers,
    ),
];

class _Picked implements PickedFile {
  const _Picked(this._file);

  final XFile _file;

  @override
  String get path => _file.path;

  @override
  String get name => _file.name;

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();
}
