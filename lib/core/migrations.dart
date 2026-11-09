import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../data/local/tree_ops.dart" show removeTree;
import "../domain/documents.dart";

/// A change to the data directory that a release makes once, to files an
/// earlier release wrote. See "Migrations" in AGENTS.md for writing one.
class Migration {
  const Migration(this.version, this.apply);

  /// The release this shipped in. A name rather than a number to compare: what
  /// runs is decided by where the entry sits in [migrations].
  final String version;

  /// A data directory rather than the `AppConfig` over it:
  /// an entry describes a layout that no longer exists, and a path helper
  /// answers for the one this build has.
  final Future<void> Function(String dataDir) apply;
}

/// The stamp in [dataDir] naming the release whose entry last ran there.
/// Not the app's version: a release that leaves the layout alone leaves it
/// where it was.
String migrationStamp(String dataDir) => p.join(dataDir, "version");

/// The chain, oldest first: each entry moves what the one above it left, and
/// nothing older.
const List<Migration> migrations = [
  Migration("7.5.0", _athena),
  Migration("7.6.0", _sharedTerminal),
];

/// 7.6.0: guest root filesystems are shared across projects. Remove the old
/// Byte Repair copy; its packages are replaced by setup in the shared rootfs.
Future<void> _sharedTerminal(String dataDir) async {
  final byteRepair = p.join(dataDir, "projects", "byte-repair");
  final oldRootfs = Directory(p.join(byteRepair, "rootfs"));
  final error = await removeTree(oldRootfs.path);
  if (error != null) throw FileSystemException(error, oldRootfs.path);
  // The marker certified setup inside that copy. It cannot certify tools in
  // the shared rootfs, so require setup to run again there.
  final marker = File(p.join(byteRepair, ".setup-complete"));
  if (marker.existsSync()) await marker.delete();
}

/// 7.5.0: the main agent is Athena, a participant like any other. Every
/// reply names its author and every say whom it was for, so a reply with no
/// author is hers and a say addressed to nobody was said to her. And a
/// message records the `/skill` and `@agent` it named rather than what they
/// meant: the `documents` map becomes `references`, its keys in order.
Future<void> _athena(String dataDir) async {
  final projects = Directory(p.join(dataDir, "projects"));
  if (!projects.existsSync()) return;
  await for (final project in projects.list()) {
    final chats = Directory(p.join(project.path, "chats"));
    if (!chats.existsSync()) continue;
    await for (final chat in chats.list()) {
      final log = File(p.join(chat.path, "conv.jsonl"));
      if (log.existsSync()) await _athenaIn(log);
    }
  }
}

Future<void> _athenaIn(File log) async {
  final lines = await log.readAsLines();
  var changed = false;
  for (var i = 0; i < lines.length; i++) {
    final Object? record;
    try {
      record = jsonDecode(lines[i]);
    } on FormatException {
      // The line a kill landed in: the reader stops there, and so does this.
      break;
    }
    if (record is! Map<String, dynamic> || record["runtimeType"] != "message") {
      continue;
    }
    final authored = record["role"] == "assistant" && record["author"] == null;
    if (authored) record["author"] = "@athena";
    final addressed =
        record["role"] == "user" &&
        ((record["addressees"] as List?) ?? const []).isEmpty;
    if (addressed) record["addressees"] = ["@athena"];
    // What the references meant goes; the names stay, in the order written.
    final documents = record.remove("documents");
    if (documents is Map) record["references"] = documents.keys.toList();
    if (!authored && !addressed && documents == null) continue;
    lines[i] = jsonEncode(record);
    changed = true;
  }
  if (changed) await writeThroughRename(log.path, "${lines.join("\n")}\n");
}

/// Bring [dataDir] to the end of [chain]. Called at launch and
/// again after a restore, since a backup unpacks the layout of the build that
/// made it, stamp and all.
///
/// [fresh] is a data directory this launch created, which is stamped and left
/// alone: without that the next release's entry would run over files that were
/// never in the shape it moves from.
///
/// [chain] is a parameter so a test can drive the engine with entries of its
/// own.
Future<void> runMigrations(
  String dataDir, {
  required bool fresh,
  List<Migration> chain = migrations,
}) async {
  if (chain.isEmpty) return;
  if (fresh) return _stamp(dataDir, chain.last);
  for (final migration in await _pending(dataDir, chain)) {
    await migration.apply(dataDir);
    // As each one goes rather than at the end: a run cut short by a kill picks
    // up at the entry it died in.
    await _stamp(dataDir, migration);
  }
}

/// Nothing, where the stamp names no entry this build has — the directory was
/// written by a newer build, and moving its files to an older idea of the
/// layout is worse than leaving them where they are. No stamp at all is a
/// directory older than every entry there is.
Future<List<Migration>> _pending(String dataDir, List<Migration> chain) async {
  final file = File(migrationStamp(dataDir));
  if (!file.existsSync()) return chain;
  final stamped = (await file.readAsString()).trim();
  final at = chain.indexWhere((migration) => migration.version == stamped);
  return at < 0 ? const [] : chain.sublist(at + 1);
}

/// Through a rename, the way every other small file here is written: a
/// `writeAsString` killed between its truncate and its write leaves a stamp
/// naming no entry, and that directory is frozen out of every migration to
/// come.
Future<void> _stamp(String dataDir, Migration migration) =>
    writeThroughRename(migrationStamp(dataDir), migration.version);
