import "dart:io" show Platform;
import "dart:typed_data";

import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show PlatformException;
import "package:image_picker/image_picker.dart" show ImagePicker, ImageSource;
import "package:entoli_core/model/file_picker.dart";
import "package:entoli_core/model/log.dart";

/// The platform's own folder and file choosers, through `file_selector` — one
/// plugin covering every platform the app runs on — and the phones' camera
/// through `image_picker`.
class FileSelectorFilePicker implements FilePicker {
  const FileSelectorFilePicker();

  // The desktops' image_picker would only open a file chooser.
  @override
  bool get canTakePhoto => Platform.isAndroid || Platform.isIOS;

  @override
  Future<PickedFile?> photo() async {
    try {
      // A phone's photo is 12 MP and more; a model reads no more than this.
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      return file == null ? null : _Picked(file);
    } on PlatformException catch (e) {
      logFailure("files", "camera: ${e.code}", e.message);
      return null;
    }
  }

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
  String? get mimeType => _file.mimeType;

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();
}
