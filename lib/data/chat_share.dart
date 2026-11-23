import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../core/config.dart";
import "../core/migrations.dart";
import "../domain/chat_share.dart";
import "../domain/models.dart";
import "../domain/workspace.dart" show safeRelativePath;

/// A shared chat is a data directory of one chat, zipped: the stamp, the
/// chat in the default project, and its workspace folder. Unzipped, it is a
/// directory `AppConfig.load` migrates like any other, which is how a link
/// from an older build reads in a newer one.
const _manifest = "share.json";

/// What the share dialog offers to send besides the conversation.
class ShareCandidates {
  const ShareCandidates({required this.workspace, required this.artifacts});

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

Future<ShareCandidates> shareCandidates(
  AppConfig config,
  String chatId, {
  String? project,
}) async {
  final workspace = config.workspaceDir(chatId, project: project);
  final artifacts = config.artifactsDir(chatId, project: project);
  return ShareCandidates(
    workspace: [
      for (final (path, size) in _files(workspace))
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

/// The link carrying [chatId] with the [workspace] files and [artifacts]
/// picked. Past [shareLinkMaxLength] the workspace goes, then the artifacts;
/// what is left out is said on the result.
Future<SharePack> packShare(
  AppConfig config,
  String chatId, {
  String? project,
  Set<String> workspace = const {},
  Set<String> artifacts = const {},
}) async {
  final conversation = await _conversation(config, chatId, project);
  final files = _workspace(config, chatId, project, workspace);
  final published = _artifacts(config, chatId, project, artifacts);
  final tiers = [
    (workspace: true, artifacts: true),
    (workspace: false, artifacts: true),
    (workspace: false, artifacts: false),
  ];
  var link = "";
  for (final tier in tiers) {
    if (!tier.workspace && files.isEmpty) continue;
    if (!tier.artifacts && published.isEmpty) continue;
    final archive = Archive();
    [
      ...conversation,
      if (tier.workspace) ...files,
      if (tier.artifacts) ...published,
    ].forEach(archive.add);
    link = shareLinkOf(ZipEncoder().encodeBytes(archive, level: 9));
    if (link.length <= shareLinkMaxLength) {
      return SharePack(
        link,
        droppedWorkspace: !tier.workspace,
        droppedArtifacts: !tier.artifacts,
      );
    }
  }
  return SharePack(
    null,
    droppedWorkspace: files.isNotEmpty,
    droppedArtifacts: published.isNotEmpty,
    length: link.length,
  );
}

Future<List<ArchiveFile>> _conversation(
  AppConfig config,
  String chatId,
  String? project,
) async {
  final shared = AppConfig.forDirectory("");
  final from = config.chatDir(chatId, project: project);
  final into = shared.chatDir(chatId);
  final state = ChatState.fromJson(
    jsonDecode(
          File(config.stateFile(chatId, project: project)).readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  // Only what says what the chat is: its project, pin, TTL and settings are
  // the sharer's, and `meta.json` names paths on their machine.
  final bare = ChatState(
    id: state.id,
    title: state.title,
    createdAt: state.createdAt,
    updatedAt: state.updatedAt,
    imported: true,
  );
  return [
    ArchiveFile.string("version", migrations.last.version),
    ArchiveFile.string(_manifest, jsonEncode({"chat": chatId})),
    ArchiveFile.string(
      _member(shared.stateFile(chatId)),
      jsonEncode(bare.toJson()),
    ),
    ArchiveFile.bytes(
      _member(shared.convFile(chatId)),
      File(config.convFile(chatId, project: project)).readAsBytesSync(),
    ),
    for (final dir in ["resources", "subagents"])
      for (final (path, _) in _files(p.join(from, dir)))
        ArchiveFile.bytes(
          _member(p.join(into, dir, path)),
          File(p.join(from, dir, path)).readAsBytesSync(),
        ),
  ];
}

List<ArchiveFile> _workspace(
  AppConfig config,
  String chatId,
  String? project,
  Set<String> picked,
) {
  final from = config.workspaceDir(chatId, project: project);
  final into = AppConfig.forDirectory("").workspaceDir(chatId);
  return [
    for (final (path, _) in _files(from))
      if (picked.contains(path))
        ArchiveFile.bytes(
          _member(p.join(into, path)),
          File(p.join(from, path)).readAsBytesSync(),
        ),
  ];
}

List<ArchiveFile> _artifacts(
  AppConfig config,
  String chatId,
  String? project,
  Set<String> picked,
) {
  final into = AppConfig.forDirectory("").artifactsDir(chatId);
  return [
    for (final id in picked)
      for (final (path, _) in _files(
        config.artifactDir(chatId, id, project: project),
      ))
        ArchiveFile.bytes(
          _member(p.join(into, id, path)),
          File(
            p.join(config.artifactDir(chatId, id, project: project), path),
          ).readAsBytesSync(),
        ),
  ];
}

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
