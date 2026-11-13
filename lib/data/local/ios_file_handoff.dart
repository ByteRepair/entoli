import "package:flutter/services.dart";

import "../../core/log.dart";
import "desktop_file_handoff.dart";

/// iOS, a desktop's routes bar the file manager, which is the Files app:
/// the workspaces are there through the Runner's File Provider extension, and
/// `FilesChannel.swift` opens Files at the folder. See "The workspaces in the
/// Files app" in ios/AGENTS.md.
class IosFileHandoff extends DesktopFileHandoff {
  const IosFileHandoff();

  static const _channel = MethodChannel("agent_chat/files");

  @override
  String get fileManager => "Files";

  @override
  Future<void> reveal(String dir) async {
    try {
      await _channel.invokeMethod<void>("reveal", {"path": dir});
    } on PlatformException catch (e) {
      logFailure("files", "opening Files failed", e);
    }
  }
}
