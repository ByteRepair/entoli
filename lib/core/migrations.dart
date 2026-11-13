import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../domain/documents.dart";
import "log.dart";

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
  Migration("8.0.0", _athena),
  Migration("8.4.0", _todaysShapes),
];

/// 8.0.0: the main agent is Athena, a participant like any other. Every
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

/// Moves a whole data directory from where an earlier release kept it to
/// [to], before the chain runs over it: iOS's, from Documents into the App
/// Group (see "The workspaces in the Files app" in ios/AGENTS.md). Not an
/// entry: an entry moves things under a data directory, and this moves the
/// directory itself, before there is one to stamp.
///
/// A rename, the two being on one volume, where a copy would be gigabytes of
/// rootfs. Where [to] is already there, or [from] is not, there is nothing to
/// move. False only where the rename failed, so the caller keeps [from].
bool relocateDataDir({required String from, required String to}) {
  final old = Directory(from);
  if (Directory(to).existsSync() || !old.existsSync()) return true;
  try {
    old.renameSync(to);
    return true;
  } on FileSystemException catch (e) {
    logFailure("migrations", "moving the data directory failed", e);
    return false;
  }
}

/// 8.4.0: what the readers used to accept in an older shape, written in
/// today's, so they read one shape. Settings under a name they had before —
/// at the app's level, a project's and a chat's — provider entries from 7.0.0
/// or older, and triggers in the reminder shape they began as.
Future<void> _todaysShapes(String dataDir) async {
  await _rewriteJson(p.join(dataDir, "settings.json"), (json) {
    final renamed = _renameSettings(json);
    final providers = _providerEntries(json);
    return renamed || providers;
  });
  final projects = Directory(p.join(dataDir, "projects"));
  if (projects.existsSync()) {
    await for (final project in projects.list()) {
      await _rewriteJson(p.join(project.path, "project.json"), _renameSettings);
      final chats = Directory(p.join(project.path, "chats"));
      if (!chats.existsSync()) continue;
      await for (final chat in chats.list()) {
        await _rewriteJson(p.join(chat.path, "meta.json"), _renameSettings);
      }
    }
  }
  await _rewriteTriggers(p.join(dataDir, "reminders.json"));
}

/// [change] edits the decoded map and says whether it did; a file that is
/// not there, or not a JSON object, is left as it is.
Future<void> _rewriteJson(
  String path,
  bool Function(Map<String, dynamic> json) change,
) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final Object? json;
  try {
    json = jsonDecode(await file.readAsString());
  } on FormatException {
    return;
  }
  if (json is! Map<String, dynamic> || !change(json)) return;
  await writeThroughRename(path, jsonEncode(json));
}

/// Each setting under the key it had before, moved under today's: kept where
/// today's key is already set, since that is the newer word.
bool _renameSettings(Map<String, dynamic> json) {
  var changed = false;
  void move(String old, String key, Object? Function(Object? value) convert) {
    if (!json.containsKey(old)) return;
    final value = convert(json.remove(old));
    if (value != null) json.putIfAbsent(key, () => value);
    changed = true;
  }

  // What the environment was called when a second backend spawned servers.
  move(
    "opencodeEnv",
    "environment",
    (v) => v is Map && v.isNotEmpty ? v : null,
  );
  move("approveCommands", "approveMode", (v) {
    return switch (v) {
      true => "ask",
      false => "never",
      _ => null,
    };
  });
  // The picker counted prompts and said chats.
  move("localModelKvCacheChats", "localModelKvCachePrompts", (v) => v);
  // A bool before it could inherit: true was a store of the project's own.
  move("useProjectMemory", "memory", (v) => v == true ? "on" : null);
  return changed;
}

/// A provider entry written by 7.0.0 or older had no name: its id was its name
/// and its models.dev id both, and a `label` said what to show. And an
/// `apiKey` left in one is dropped: keys live in the secret store, and the
/// reader never took it.
bool _providerEntries(Map<String, dynamic> json) {
  final entries = json["llmProviders"];
  if (entries is! List) return false;
  var changed = false;
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    if (entry.remove("apiKey") != null) changed = true;
    if (entry.containsKey("name")) continue;
    final label = entry.remove("label");
    entry["name"] = label is String ? label : entry["id"];
    entry["catalogId"] ??= entry["id"];
    changed = true;
  }
  return changed;
}

/// A trigger began as a reminder: its schedule in flat `at` and `repeat` keys
/// rather than a `source`, and a `temporary` bool where the TTL now is, false
/// meaning the one TTL a bool could name.
Future<void> _rewriteTriggers(String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final Object? list;
  try {
    list = jsonDecode(await file.readAsString());
  } on FormatException {
    return;
  }
  if (list is! List) return;
  var changed = false;
  for (final trigger in list) {
    if (trigger is! Map<String, dynamic>) continue;
    if (trigger["source"] is! Map) {
      final at = trigger.remove("at");
      final repeat = trigger.remove("repeat");
      trigger["source"] = {"kind": "schedule", "at": ?at, "repeat": ?repeat};
      changed = true;
    }
    if (trigger.containsKey("temporary")) {
      final temporary = trigger.remove("temporary");
      if (temporary == false) trigger.putIfAbsent("tempChatTtl", () => "off");
      changed = true;
    }
  }
  if (changed) await writeThroughRename(path, jsonEncode(list));
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
