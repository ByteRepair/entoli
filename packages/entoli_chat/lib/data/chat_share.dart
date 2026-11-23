import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter/foundation.dart" show compute;
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../core/config.dart";
import "../core/migrations.dart";
import "../domain/chat_share.dart";
import "../domain/link_bytes.dart" show appLinkMaxLength;
import "../domain/models.dart";
import "../domain/workspace.dart" show safeRelativePath;

/// A shared chat is a data directory of one chat, zipped: the stamp, the
/// chat in the default project, and its workspace folder. Unzipped, it is a
/// directory `AppConfig.load` migrates like any other, which is how a link
/// from an older build reads in a newer one.
const _manifest = "share.json";

/// What the share dialog offers to send besides the conversation.
class ShareCandidates {
  const ShareCandidates({
    required this.attachments,
    required this.workspace,
    required this.artifacts,
  });

  /// Every file attached to or made in the chat's messages, by resource name.
  final List<ShareFile> attachments;

  /// Every file in the chat's workspace folder, by its path under it.
  final List<ShareFile> workspace;

  /// Every artifact the chat published, by its id.
  final List<ShareFile> artifacts;
}

class ShareFile {
  const ShareFile(this.path, this.size, {required this.suggested});

  final String path;
  final int size;

  /// Off where [isShareIgnored] says it is a secret or a build tree.
  final bool suggested;
}

/// One chat as something to share: what it could carry, what each piece
/// costs in the link, and the link itself for the pieces picked.
class ChatShareSource {
  ChatShareSource(this.config, this.chatId, {this.project});

  final AppConfig config;
  final String chatId;
  final String? project;

  /// Where every member goes in the zip: a data directory of this chat
  /// alone, in the default project.
  static final _shared = AppConfig.forDirectory("");

  Future<ShareCandidates> candidates() async {
    final artifacts = config.artifactsDir(chatId, project: project);
    return ShareCandidates(
      attachments: [
        for (final (path, size) in _files(_from(ShareSection.attachments)))
          ShareFile(path, size, suggested: true),
      ],
      workspace: [
        for (final (path, size) in _files(_from(ShareSection.workspace)))
          ShareFile(path, size, suggested: !isShareIgnored(path)),
      ],
      artifacts: [
        if (Directory(artifacts).existsSync())
          for (final dir in Directory(
            artifacts,
          ).listSync().whereType<Directory>())
            ShareFile(
              p.basename(dir.path),
              _files(dir.path).fold(0, (sum, f) => sum + f.$2),
              suggested: true,
            ),
      ],
    );
  }

  /// What the zip costs with nothing picked: the conversation, and the
  /// directory's end record. See [shareFit].
  Future<int> base() async =>
      await compute(_cost, _conversation()) + _endRecord;

  /// What [id] in [section] adds to the zip, in bytes.
  Future<int> cost(ShareSection section, String id) =>
      compute(_cost, _members(section, id));

  /// The link carrying the conversation and [picks], or null where it is
  /// past [appLinkMaxLength]: the dialog decides what is left out, from
  /// [shareFit], before anything is packed.
  Future<String?> pack(SharePicks picks) async {
    final entries = [
      ..._conversation(),
      for (final MapEntry(key: section, value: ids) in picks.entries)
        for (final id in ids) ..._members(section, id),
    ];
    final link = shareLinkOf(await compute(_zip, entries));
    return link.length <= appLinkMaxLength ? link : null;
  }

  String _from(ShareSection section) => switch (section) {
    ShareSection.attachments => config.resourcesDir(chatId, project: project),
    ShareSection.workspace => config.workspaceDir(chatId, project: project),
    ShareSection.artifacts => config.artifactsDir(chatId, project: project),
  };

  String _into(ShareSection section) => switch (section) {
    ShareSection.attachments => _shared.resourcesDir(chatId),
    ShareSection.workspace => _shared.workspaceDir(chatId),
    ShareSection.artifacts => _shared.artifactsDir(chatId),
  };

  /// An attachment and a workspace file are one file; an artifact is its
  /// directory.
  List<_Entry> _members(ShareSection section, String id) {
    final from = p.join(_from(section), id);
    final into = p.join(_into(section), id);
    if (section != ShareSection.artifacts) {
      return File(from).existsSync() ? [_read(_member(into), from)] : const [];
    }
    return [
      for (final (path, _) in _files(from))
        _read(_member(p.join(into, path)), p.join(from, path)),
    ];
  }

  List<_Entry> _conversation() {
    final from = config.chatDir(chatId, project: project);
    final into = _shared.chatDir(chatId);
    final state = ChatState.fromJson(
      jsonDecode(
            File(config.stateFile(chatId, project: project)).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
    // Only what says what the chat is: its project, pin, TTL and settings
    // are the sharer's, and `meta.json` names paths on their machine.
    final bare = ChatState(
      id: state.id,
      title: state.title,
      createdAt: state.createdAt,
      updatedAt: state.updatedAt,
      imported: true,
    );
    _Entry text(String name, String text) =>
        (name: name, bytes: utf8.encode(text));
    return [
      text("version", migrations.last.version),
      text(_manifest, jsonEncode({"chat": chatId})),
      text(_member(_shared.stateFile(chatId)), jsonEncode(bare.toJson())),
      _read(
        _member(_shared.convFile(chatId)),
        config.convFile(chatId, project: project),
      ),
      for (final (path, _) in _files(p.join(from, "subagents")))
        _read(
          _member(p.join(into, "subagents", path)),
          p.join(from, "subagents", path),
        ),
    ];
  }
}

/// A zip member, read. The files are read here and only the compressing is
/// handed to [compute]'s isolate, which has none of this one's `IOOverrides`
/// — the viewer's in-memory disk among them.
typedef _Entry = ({String name, Uint8List bytes});

_Entry _read(String name, String path) =>
    (name: name, bytes: File(path).readAsBytesSync());

/// The end-of-central-directory record every zip closes with, no comment.
const _endRecord = 22;

Uint8List _zip(List<_Entry> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(ArchiveFile.bytes(entry.name, entry.bytes));
  }
  return ZipEncoder().encodeBytes(archive, level: 9);
}

/// What [entries] add to a zip: each zipped alone, less the end record
/// they would otherwise share.
int _cost(List<_Entry> entries) =>
    entries.fold(0, (sum, entry) => sum + _zip([entry]).length - _endRecord);

/// Every file under [dir], by its `/`-separated path under it, with its size.
List<(String, int)> _files(String dir) {
  if (!Directory(dir).existsSync()) return const [];
  return [
    for (final entity in Directory(
      dir,
    ).listSync(recursive: true, followLinks: false))
      if (entity is File)
        (
          p.split(p.relative(entity.path, from: dir)).join("/"),
          entity.lengthSync(),
        ),
  ];
}

String _member(String path) => p.split(p.normalize(path)).join("/");

/// [zip] written out as a data directory at [dataDir] and brought up to this
/// build's layout. Answers the shared chat's id, or null where the zip is not
/// a shared chat. Members land only under the chat's own folders.
Future<String?> unpackShare(Uint8List zip, String dataDir) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zip);
  } catch (_) {
    return null;
  }
  final manifest = archive.findFile(_manifest)?.readBytes();
  final stamp = archive.findFile("version")?.readBytes();
  if (manifest == null || stamp == null) return null;
  final chatId = (jsonDecode(utf8.decode(manifest)) as Map)["chat"];
  if (chatId is! String || safeRelativePath(chatId) != chatId) return null;
  final shared = AppConfig.forDirectory(dataDir);
  final roots = [shared.chatDir(chatId), shared.workspaceDir(chatId)];
  for (final member in archive) {
    if (member.isDirectory) continue;
    final target = p.join(dataDir, safeRelativePath(member.name));
    if (!roots.any((root) => p.isWithin(root, target))) continue;
    final file = File(target);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(member.readBytes() ?? Uint8List(0));
  }
  if (!File(shared.convFile(chatId)).existsSync()) return null;
  await File(migrationStamp(dataDir)).writeAsBytes(stamp);
  await AppConfig.load(dataDir);
  return chatId;
}

/// [zip] as a new chat in [project]: the conversation, what was attached,
/// published and in its workspace, under a new id, marked imported until the
/// user enables it. Answers the new chat's id, or null where the zip is not a
/// shared chat.
Future<String?> importShare(
  Uint8List zip,
  AppConfig config, {
  String? project,
}) async {
  final temp = await Directory.systemTemp.createTemp("entoli-share");
  try {
    final from = await unpackShare(zip, temp.path);
    if (from == null) return null;
    final shared = AppConfig.forDirectory(temp.path);
    final id = const Uuid().v4();
    await _copyTree(shared.chatDir(from), config.chatDir(id, project: project));
    await _copyTree(
      shared.workspaceDir(from),
      config.workspaceDir(id, project: project),
    );
    final stateFile = config.stateFile(id, project: project);
    final state = ChatState.fromJson(
      jsonDecode(File(stateFile).readAsStringSync()) as Map<String, dynamic>,
    );
    await File(stateFile).writeAsString(
      jsonEncode(
        state
            .copyWith(
              id: id,
              project: project,
              imported: true,
              updatedAt: DateTime.now(),
            )
            .toJson(),
      ),
    );
    return id;
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _copyTree(String from, String to) async {
  for (final (path, _) in _files(from)) {
    final target = File(p.join(to, path));
    await target.parent.create(recursive: true);
    await File(p.join(from, path)).copy(target.path);
  }
}
