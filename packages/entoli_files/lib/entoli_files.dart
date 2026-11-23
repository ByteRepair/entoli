import "dart:io";

import "package:entoli_core/model/attachment_picker.dart";
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

/// The chooser an attachment comes from.
AttachmentPicker platformAttachmentPicker() => const FileSelectorPicker();

/// The chooser for a folder or for files.
FilePicker platformFilePicker() => const FileSelectorFilePicker();

/// Opening, showing and sharing a workspace file, and taking one shared in.
FileHandoff platformFileHandoff() => Platform.isAndroid
    ? AndroidFileHandoff()
    : Platform.isIOS
    ? const IosFileHandoff()
    : const DesktopFileHandoff();

/// Android has no save dialog; a backup leaves through the share sheet.
BackupHandoff platformBackupHandoff(FileHandoff handoff) =>
    Platform.isAndroid ? SharedBackup(handoff) : const FileSelectorBackup();
