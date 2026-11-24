import "dart:typed_data";

import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show PlatformException;
import "package:image_picker/image_picker.dart" show ImagePicker, ImageSource;
import "package:entoli_core/model/file_picker.dart";
import "package:entoli_core/model/log.dart";

/// The platform's own folder and file choosers, through `file_selector` — one
/// plugin covering every platform the app runs on — and, where [canTakePhoto],
/// the camera through `image_picker`.
class FileSelectorFilePicker implements FilePicker {
  const FileSelectorFilePicker({this.canTakePhoto = false});

  @override
  final bool canTakePhoto;

  @override
  Future<PickedFile?> photo() async {
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.camera);
      return file == null ? null : _Picked(file);
    } on PlatformException catch (e) {
      // camera_access_denied, no_available_camera.
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
