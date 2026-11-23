import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter/foundation.dart" show compute;
import "package:path/path.dart" as p;

import "../core/config.dart";
import "../core/log.dart";
import "../core/migrations.dart";
import "../domain/chat_share.dart";
import "../domain/chat_store.dart";
import "../domain/link_bytes.dart" show appLinkMaxLength;
import "../domain/models.dart";
import "../domain/workspace.dart" show safeRelativePath;
import "zip.dart";

/// A shared chat is a data directory of one chat, zipped: the stamp, the
/// chat in the default project, and its workspace folder. Unzipped, it is a
/// directory `AppConfig.load` migrates like any other, which is how a link
/// from an older build reads in a newer one.
const _manifest = "share.json";

/// What the share dialog offers to send besides the conversation, by
/// section: every attachment by resource name, every artifact by id, and
/// every workspace file by its path under the workspace.
typedef ShareCandidates = Map<ShareSection, List<ShareFile>>;

class ShareFile {
  const ShareFile(
    this.path,
    this.size, {
    required this.suggested,
    this.folder = false,
  });

  final String path;
  final int size;

  /// Off where [isShareIgnored] says it is a secret or a build tree.
  final bool suggested;

  /// A workspace folder [isShareIgnoredDir] names, offered whole rather than
  /// walked; its [size] is not counted.
  final bool folder;
}

/// One thing the dialog can tick: an id in its section.
typedef SharePiece = (ShareSection, String);

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

  /// What has been compressed, kept for [pack]: one single-member zip per
  /// file. A zip compresses each member alone, so these join unchanged.
  final _zipped = <SharePiece, List<Uint8List>>{};
  Future<List<Uint8List>>? _conversation;

  Future<ShareCandidates> candidates() async => {
    for (final section in ShareSection.values) section: await _list(section),
  };

  Future<List<ShareFile>> _list(ShareSection section) async {
    final dir = _dir(config, section, chatId, project: project);
    if (!Directory(dir).existsSync()) return const [];
    if (section == ShareSection.artifacts) {
      return [
        await for (final entity in Directory(dir).list())
          if (entity is Directory)
            ShareFile(
              p.basename(entity.path),
              await _sizeOf(entity.path),
              suggested: true,
            ),
      ];
    }
    final files = <ShareFile>[];
    final workspace = section == ShareSection.workspace;
    // An ignored folder is one unticked line, not walked: a `node_modules`
    // is thousands of files nobody means to send.
    bool skipDir(String path) {
      if (path == dir || !isShareIgnoredDir(p.basename(path))) return false;
      files.add(
        ShareFile(_under(dir, path), 0, suggested: false, folder: true),
      );
      return true;
    }

    await for (final entry in _shareTree(
      dir,
      skipDir: workspace ? skipDir : null,
    )) {
      if (entry.isDirectory) continue;
      files.add(
        ShareFile(
          entry.name,
          await File(entry.path).length(),
          suggested: !workspace || !isShareIgnored(entry.name),
        ),
      );
    }
    return files;
  }

  /// What the zip costs with nothing picked: the conversation, and the
  /// directory's end record. See [shareFit].
  Future<int> base() async =>
      _sum(await (_conversation ??= _zipConversation())) + _endRecord;

  Future<List<Uint8List>> _zipConversation() async =>
      compute(_zipEach, await _conversationEntries());

  /// What each of [pieces] adds to the zip, in bytes, compressed in one
  /// isolate. A piece too big to fit whatever it compresses to is answered a
  /// lower bound past the room there is, unread; one that cannot be read is
  /// left out of the answer.
  Future<Map<SharePiece, int>> measure(Iterable<SharePiece> pieces) async {
    final room = _maxZip - await base();
    final costs = <SharePiece, int>{};
    final read = <SharePiece, List<_Entry>>{};
    var pending = 0;
    Future<void> flush() async {
      await _zipPieces(read);
      for (final piece in read.keys) {
        costs[piece] = _sum(_zipped[piece]!);
      }
      read.clear();
      pending = 0;
    }

    for (final piece in pieces) {
      if (_zipped[piece] case final zips?) {
        costs[piece] = _sum(zips);
        continue;
      }
      try {
        final members = await _members(piece);
        var raw = 0;
        for (final member in members) {
          raw += await File(member.path).length();
        }
        final least = raw ~/ _deflateMaxRatio;
        if (least > room) {
          costs[piece] = least;
          continue;
        }
        read[piece] = await _read(members);
        pending += raw;
      } catch (e) {
        logFailure("share", "reading a ${piece.$1.name} piece failed", e);
      }
      // Held in memory until compressed, so a big batch goes in parts.
      if (pending > _batchBytes) await flush();
    }
    if (read.isNotEmpty) await flush();
    return costs;
  }

  /// The link carrying the conversation and [picks], or null where it is
  /// past [appLinkMaxLength]: the dialog decides what is left out, from
  /// [shareFit], before anything is packed. What was measured is not read or
  /// compressed again.
  Future<String?> pack(SharePicks picks) async {
    final pieces = [
      for (final MapEntry(key: section, value: ids) in picks.entries)
        for (final id in ids) (section, id),
    ];
    await _zipPieces({
      for (final piece in pieces)
        if (!_zipped.containsKey(piece))
          piece: await _read(await _members(piece)),
    });
    final zips = [
      ...await (_conversation ??= _zipConversation()),
      for (final piece in pieces) ..._zipped[piece]!,
    ];
    final link = shareLinkOf(await compute(_join, zips));
    return link.length <= appLinkMaxLength ? link : null;
  }

  Future<void> _zipPieces(Map<SharePiece, List<_Entry>> read) async {
    if (read.isEmpty) return;
    final pieces = read.keys.toList();
    final zipped = await compute(_zipAll, [
      for (final piece in pieces) read[piece]!,
    ]);
    for (var i = 0; i < pieces.length; i++) {
      _zipped[pieces[i]] = zipped[i];
    }
  }

  /// The files [piece] puts in the zip: an attachment or a workspace file is
  /// one, an artifact or a workspace folder every file under it.
  Future<List<_Member>> _members(SharePiece piece) async {
    final (section, id) = piece;
    final from = p.join(_dir(config, section, chatId, project: project), id);
    final into = p.join(_dir(_shared, section, chatId), id);
    if (FileSystemEntity.isFileSync(from)) {
      return [(name: _member(into), path: from)];
    }
    if (!FileSystemEntity.isDirectorySync(from)) return const [];
    return _membersUnder(from, into);
  }

  Future<List<_Entry>> _conversationEntries() async {
    final state = ChatState.fromJson(
      jsonDecode(
            await File(
              config.stateFile(chatId, project: project),
            ).readAsString(),
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
    final subAgents = config.subAgentsDir(chatId, project: project);
    return [
      text("version", migrations.last.version),
      text(_manifest, jsonEncode({"chat": chatId})),
      text(_member(_shared.stateFile(chatId)), jsonEncode(bare.toJson())),
      ...await _read([
        (
          name: _member(_shared.convFile(chatId)),
          path: config.convFile(chatId, project: project),
        ),
        if (Directory(subAgents).existsSync())
          ...await _membersUnder(subAgents, _shared.subAgentsDir(chatId)),
      ]),
    ];
  }
}

/// Where [section] of a chat is under [config].
String _dir(
  AppConfig config,
  ShareSection section,
  String chatId, {
  String? project,
}) => switch (section) {
  ShareSection.attachments => config.resourcesDir(chatId, project: project),
  ShareSection.workspace => config.workspaceDir(chatId, project: project),
  ShareSection.artifacts => config.artifactsDir(chatId, project: project),
};

/// A file on disk, and its name in the zip.
typedef _Member = ({String name, String path});

/// Everything under [dir], named from it. A link is no part of it: a share
/// goes to someone else, and what a link points at is not the chat's to give.
Stream<TreeEntry> _shareTree(
  String dir, {
  bool Function(String path)? skipDir,
}) => walkTree([dir], base: dir, skipDir: skipDir, followLinks: false);

/// Every file under [from], named as it would be under [into].
Future<List<_Member>> _membersUnder(String from, String into) async => [
  await for (final entry in _shareTree(from))
    if (!entry.isDirectory)
      (name: _member(p.join(into, entry.name)), path: entry.path),
];

/// A zip member, read. The files are read here and only the compressing is
/// handed to [compute]'s isolate, which has none of this one's `IOOverrides`
/// — the viewer's in-memory disk among them.
typedef _Entry = ({String name, Uint8List bytes});

Future<List<_Entry>> _read(List<_Member> members) async => [
  for (final member in members)
    (name: member.name, bytes: await File(member.path).readAsBytes()),
];

/// The end-of-central-directory record every zip closes with, no comment.
const _endRecord = 22;

/// The most a zip can be for its link to fit.
final _maxZip = (appLinkMaxLength - shareLinkLength(0)) * 3 ~/ 4;

/// Deflate's best ratio, one 258-byte match per two bits: no file comes out
/// smaller than this fraction of itself.
const _deflateMaxRatio = 1032;

/// How much [ChatShareSource.measure] reads before compressing it.
const _batchBytes = 32 << 20;

/// [entries], each zipped alone.
List<Uint8List> _zipEach(List<_Entry> entries) => [
  for (final entry in entries)
    ZipEncoder().encodeBytes(
      Archive()..add(ArchiveFile.bytes(entry.name, entry.bytes)),
      level: 9,
    ),
];

List<List<Uint8List>> _zipAll(List<List<_Entry>> pieces) => [
  for (final entries in pieces) _zipEach(entries),
];

/// Single-member zips as one, their compressed data copied over as it is.
Uint8List _join(List<Uint8List> zips) {
  final archive = Archive();
  for (final zip in zips) {
    for (final file in ZipDecoder().decodeBytes(zip)) {
      // Unset, the encoder inflates the member again to work it out.
      if (file.rawContent case final ZipFile content) {
        file.crc32 = content.crc32;
      }
      archive.add(file);
    }
  }
  return ZipEncoder().encodeBytes(archive, level: 9);
}

/// What single-member [zips] add to the zip they are joined into: each less
/// the end record they would otherwise share.
int _sum(List<Uint8List> zips) =>
    zips.fold(0, (sum, zip) => sum + zip.length - _endRecord);

String _member(String path) => p.split(p.normalize(path)).join("/");

String _under(String dir, String path) =>
    p.split(p.relative(path, from: dir)).join("/");

Future<int> _sizeOf(String dir) async {
  var size = 0;
  await for (final entry in _shareTree(dir)) {
    if (!entry.isDirectory) size += await File(entry.path).length();
  }
  return size;
}

/// What [unpackShare] answers: the unpacked data directory, loaded, and the
/// shared chat's id in it.
typedef UnpackedShare = ({AppConfig config, String chatId});

/// [zip] written out as a data directory at [dataDir] and brought up to this
/// build's layout. Null where the zip is not a shared chat. Members land only
/// under the chat's own folders.
Future<UnpackedShare?> unpackShare(Uint8List zip, String dataDir) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zip);
  } catch (_) {
    return null;
  }
  final manifest = archive.findFile(_manifest)?.readBytes();
  final stamp = archive.findFile("version")?.readBytes();
  if (manifest == null || stamp == null) return null;
  final Object? chatId;
  try {
    chatId = (jsonDecode(utf8.decode(manifest)) as Map)["chat"];
  } catch (_) {
    return null;
  }
  if (chatId is! String || safeRelativePath(chatId) != chatId) return null;
  final shared = AppConfig.forDirectory(dataDir);
  // What a share packs and nothing else: a `meta.json`, which the sharer
  // never sends, would set the imported chat's approvals and sandbox.
  final files = {shared.convFile(chatId), shared.stateFile(chatId)};
  final roots = [
    shared.resourcesDir(chatId),
    shared.artifactsDir(chatId),
    shared.subAgentsDir(chatId),
    shared.workspaceDir(chatId),
  ];
  await extractInto(
    archive,
    dataDir,
    accept: (target) =>
        files.contains(target) || roots.any((root) => p.isWithin(root, target)),
  );
  if (!files.every((file) => File(file).existsSync())) return null;
  await File(migrationStamp(dataDir)).writeAsBytes(stamp);
  final AppConfig config;
  try {
    config = await AppConfig.load(dataDir);
    // After the migrations, which bring an older state to today's shape; a
    // newer build's may still be one this cannot read.
    ChatState.fromJson(
      jsonDecode(await File(shared.stateFile(chatId)).readAsString())
          as Map<String, dynamic>,
    );
  } catch (e) {
    logFailure("share", "a shared chat could not be read", e);
    return null;
  }
  return (config: config, chatId: chatId);
}

/// [zip] as a new chat in [project] of [store]: see [ChatStore.importChat].
/// Null where the zip is not a shared chat.
Future<String?> importShare(
  Uint8List zip,
  ChatStore store, {
  String? project,
}) async {
  final temp = await Directory.systemTemp.createTemp("entoli-share");
  try {
    final unpacked = await unpackShare(zip, temp.path);
    if (unpacked == null) return null;
    return await store.importChat(
      unpacked.config.dataDir,
      unpacked.chatId,
      project: project,
    );
  } finally {
    await temp.delete(recursive: true);
  }
}
