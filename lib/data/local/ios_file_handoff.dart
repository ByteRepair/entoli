import "package:flutter/services.dart";
import "package:url_launcher/url_launcher.dart";

import "../../core/log.dart";
import "../../domain/file_handoff.dart";

/// iOS, whose file manager is the Files app: the workspaces are there through
/// the Runner's File Provider extension, and `FilesChannel.swift` opens Files
/// at the folder. A file opens the way a desktop's does, and there is no share
/// sheet here yet. See "The workspaces in the Files app" in ios/AGENTS.md.
class IosFileHandoff implements FileHandoff {
  const IosFileHandoff();

  static const _channel = MethodChannel("agent_chat/files");

  @override
  String get fileManager => "Files";

  @override
  bool get canShare => false;

  @override
  Future<void> open(String path) async {
    await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> reveal(String dir) async {
    try {
      await _channel.invokeMethod<void>("reveal", {"path": dir});
    } on PlatformException catch (e) {
      logFailure("files", "opening Files failed", e);
    }
  }

  @override
  Future<void> export(List<String> paths) async {}

  @override
  Future<List<IncomingFile>> takeShare() async => const [];

  @override
  Stream<void> get shareArrived => const Stream.empty();
}
