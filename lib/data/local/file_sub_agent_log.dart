import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../domain/chat_log.dart";
import "../../domain/models.dart";
import "../../domain/sub_agent_log.dart";

/// One chat's sub-agent transcripts, under `<chat>/subagents/`. Bound to a chat
/// and a project because a sub-agent belongs to the turn that spawned it and
/// there is nothing to look it up by otherwise — unlike `FileChatStore`, which
/// has to find a chat by id alone.
class FileSubAgentLog implements SubAgentLog {
  FileSubAgentLog(this.config, this.chatId, {this.project, this.feed});

  final AppConfig config;
  final String chatId;
  final String? project;

  /// Where a running transcript is held and announced as it is written. Null
  /// where nothing follows one.
  final SubAgentFeed? feed;

  FileSystem get _fs => config.fs;

  String _path(String callId) =>
      config.subAgentFile(chatId, callId, project: project);

  @override
  Future<void> append(String callId, List<ChatRecord> records) async {
    if (records.isEmpty) return;
    final feed = this.feed;
    if (feed != null && !feed.holds(chatId, callId)) {
      feed.open(chatId, callId, await this.records(callId));
    }
    // Unlike a chat's log, nothing has created this directory: a sub-agent's
    // first record is the first thing to name it.
    await _fs.directory(config.subAgentsDir(chatId, project: project)).create(recursive: true);
    await _fs.file(_path(callId)).writeAsString(encodeLog(records), mode: FileMode.append);
    feed?.add(chatId, callId, records);
  }

  @override
  Future<List<Message>> read(String callId) async =>
      replay(await records(callId));

  @override
  Future<bool> isResumable(String callId) async {
    final records = await this.records(callId);
    return records.isNotEmpty && endsUnfinished(replay(records), records);
  }

  Future<List<ChatRecord>> records(String callId) async {
    final file = _fs.file(_path(callId));
    if (!await file.exists()) return const [];
    return decodeLog(await file.readAsString());
  }
}
