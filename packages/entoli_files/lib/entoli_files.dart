import "dart:io";

import "package:entoli_core/model/backup_handoff.dart";
import "package:entoli_core/model/file_handoff.dart";
import "package:entoli_core/model/file_picker.dart";
import "package:image_picker_android/image_picker_android.dart";
import "package:image_picker_platform_interface/image_picker_platform_interface.dart"
    show ImagePickerPlatform;

import "android_file_handoff.dart";
import "backup_handoff.dart";
import "desktop_file_handoff.dart";
import "file_selector_picker.dart";
import "ios_file_handoff.dart";
import "shared_backup.dart";

export "zip.dart" show zipTo;

/// The chooser for a folder or for files, and the phones' camera and photo
/// library.
FilePicker platformFilePicker() {
  // Below Android 16 the plugin's default is the old ACTION_GET_CONTENT
  // chooser rather than the system Photo Picker.
  final platform = ImagePickerPlatform.instance;
  if (platform is ImagePickerAndroid) platform.useAndroidPhotoPicker = true;
  return const FileSelectorFilePicker();
}

/// Opening, showing and sharing a workspace file, and taking one shared in.
FileHandoff platformFileHandoff() => Platform.isAndroid
    ? AndroidFileHandoff()
    : Platform.isIOS
    ? const IosFileHandoff()
    : const DesktopFileHandoff();

/// Android has no save dialog; a backup leaves through the share sheet.
BackupHandoff platformBackupHandoff(FileHandoff handoff) =>
    Platform.isAndroid ? SharedBackup(handoff) : const FileSelectorBackup();
