import "dart:io";

import "package:entoli_core/model/backup_handoff.dart";
import "package:entoli_core/model/file_handoff.dart";
import "package:entoli_core/model/file_picker.dart";

import "android_file_handoff.dart";
import "backup_handoff.dart";
import "desktop_file_handoff.dart";
import "file_selector_picker.dart";
import "ios_file_handoff.dart";
import "shared_backup.dart";

export "zip.dart" show zipTo;

/// The chooser for a folder or for files, and the phones' camera.
FilePicker platformFilePicker() =>
    FileSelectorFilePicker(canTakePhoto: Platform.isAndroid || Platform.isIOS);

/// Opening, showing and sharing a workspace file, and taking one shared in.
FileHandoff platformFileHandoff() => Platform.isAndroid
    ? AndroidFileHandoff()
    : Platform.isIOS
    ? const IosFileHandoff()
    : const DesktopFileHandoff();

/// Android has no save dialog; a backup leaves through the share sheet.
BackupHandoff platformBackupHandoff(FileHandoff handoff) =>
    Platform.isAndroid ? SharedBackup(handoff) : const FileSelectorBackup();
