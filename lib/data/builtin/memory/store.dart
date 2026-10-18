import "dart:convert";

import "package:fs_shim/fs.dart";
import "package:uuid/uuid.dart";

import "../../../domain/documents.dart" show RenameWriter;

/// A project's auto-memory: small durable facts that accumulate as turns
/// happen and are recalled into the turns they are relevant to. The store is
/// app-managed, at `<project>/memory/` beside `chats/` and `workspace/` —
/// outside the workspaces, so the agent's file tools cannot reach it and only
/// its memory tools and the explorer can.
///
/// Two files. `memories.jsonl` is the log and the source of truth,
/// append-only like `conv.jsonl`: a memory is a line, and deleting one is a
/// tombstone line naming its id, so the last record for an id stands. A torn
/// last line is where a killed write landed, so the replay stops there rather
/// than guessing at it. `index.json` is the full-text index derived from the
/// log: it is a convenience, so a stale or broken one is rebuilt and a missing
/// one costs nothing.
const _logName = "memories.jsonl";
const _indexName = "index.json";
const _consolidatedName = "consolidated";

/// How many memories a search may return.
const recallLimit = 5;

/// The bar a memory has to clear to be recalled. Each query word that appears
/// in a memory adds the share of memories that word is in, so a word only one
/// memory carries is worth 1 and a word every memory shares is worth little.
/// Under 1, nothing matched specifically enough.
const double recallMinScore = 1;

/// Caps on what a recall block may carry, per memory and in total: a chatty
/// store must not crowd the prompt out.
const recallEntryChars = 400;
const recallBlockChars = 2000;

/// Caps on the index block: a line per memory, and a ceiling on the block so
/// a large store does not take the prompt with it.
const indexEntryChars = 150;
const indexBlockChars = 4000;

/// What a consolidation pass is owed, and how often it may come: the store
/// must have grown past [consolidationMinEntries] live memories, and the last
/// pass must be at least [consolidationMinInterval] old, before the pass
/// earns its background model call.
const consolidationMinEntries = 15;
const consolidationMinInterval = Duration(hours: 1);

/// The ceiling on the entries a consolidation pass is shown: past this the
/// oldest are left out of the question, which is to say, of the tidying.
const consolidationMaxEntries = 50;

/// How many pinned memories a turn carries in full: the pin is the user's way
/// of saying "this is in every turn", and a standing order that crowds out the
/// turn it is standing over has stopped being one.
const pinnedLimit = 4;

/// A memory, replayed out of the log. [chat] is the one that wrote it, or
/// null where the user typed it in the explorer.
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.text,
    required this.at,
    this.chat,
    this.pinned = false,
  });

  final String id;
  final String text;
  final DateTime at;
  final String? chat;

  /// Whether the user pinned it: pinned memories go into every turn in full
  /// rather than waiting on a recall.
  final bool pinned;

  MemoryEntry copyWithPinned(bool pinned) => MemoryEntry(
        id: id,
        text: text,
        at: at,
        chat: chat,
        pinned: pinned,
      );

  /// The wire's shape, for a paired device's memory page.
  Map<String, dynamic> toJson() => {
        "id": id,
        "text": text,
        "at": at.toIso8601String(),
        "chat": ?chat,
        "pinned": pinned,
      };

  factory MemoryEntry.fromJson(Map<String, dynamic> json) => MemoryEntry(
        id: json["id"] as String,
        text: json["text"] as String,
        at: DateTime.parse(json["at"] as String),
        chat: json["chat"] as String?,
        pinned: json["pinned"] as bool? ?? false,
      );
}

/// What the memory page reads and changes: this device's [MemoryStore], or a
/// paired device's over the wire.
abstract interface class Memories {
  Future<List<MemoryEntry>> entries();
  Future<List<MemoryEntry>> search(String query);
  Future<void> add(String text);
  Future<void> pin(String id);
  Future<void> unpin(String id);
  Future<void> delete(String id);
}

class MemoryStore implements Memories {
  MemoryStore(this.fs, this.dir) : _writer = RenameWriter.fs(fs);

  final FileSystem fs;
  final String dir;

  /// The stamp and the index both — this store owns their paths, and one
  /// writer is what the fixed rename temp asks for.
  final RenameWriter _writer;

  String get _logPath => fs.path.join(dir, _logName);
  String get _indexPath => fs.path.join(dir, _indexName);
  String get _consolidatedPath => fs.path.join(dir, _consolidatedName);

  /// Every live memory, oldest first.
  @override
  Future<List<MemoryEntry>> entries() async => _replay(await _readLog());

  /// Adds a memory. [chat] names the one that wrote it, or null for a manual
  /// one from the explorer. Throws on empty text.
  @override
  Future<MemoryEntry> add(String text, {String? chat}) =>
      _write(const Uuid().v4(), text, chat);

  /// A tombstone for [id]. One for a memory that is not there is a line the
  /// replay ignores.
  @override
  Future<void> delete(String id) async {
    await _append(_marker("d", id));
    await _rebuildIndex();
  }

  /// Replaces the text of [id]. The log stays append-only: a new record with
  /// the same id, and the replay's last-record-stands makes it a replacement
  /// rather than a duplicate. Null, and nothing written, where [id] is not a
  /// live memory: a record after a tombstone would never be read. Throws on
  /// empty text.
  Future<MemoryEntry?> update(String id, String text, {String? chat}) async {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, "text", "must not be empty");
    }
    if (!(await entries()).any((e) => e.id == id)) return null;
    return _write(id, text, chat);
  }

  Future<MemoryEntry> _write(String id, String text, String? chat) async {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, "text", "must not be empty");
    }
    final entry = MemoryEntry(
      id: id,
      text: text.trim(),
      at: DateTime.now().toUtc(),
      chat: chat,
    );
    await _append(_memoryRecord(entry.id, entry.text, entry.at, chat));
    await _rebuildIndex();
    return entry;
  }

  /// Marks [id] as pinned, so it reaches every turn in full rather than
  /// waiting on a recall. Pinning an id that is not there is a line the
  /// replay ignores, the way a stray tombstone is.
  @override
  Future<void> pin(String id) => _pinRecord(id, true);

  /// The undo of [pin]: the last pin or unpin for an id stands.
  @override
  Future<void> unpin(String id) => _pinRecord(id, false);

  Future<void> _pinRecord(String id, bool pinned) =>
      _append(_marker(pinned ? "p" : "u", id));

  /// A tombstone (`d`), pin (`p`) or unpin (`u`) line for [id].
  static String _marker(String type, String id) => jsonEncode({
        "t": type,
        "id": id,
        "at": DateTime.now().toUtc().toIso8601String(),
      });

  /// When the store was last tidied by a consolidation pass, for the interval
  /// between passes. Nothing stamped, and a stamp that will not parse — a torn
  /// write —, both read as never.
  Future<DateTime?> lastConsolidated() async {
    final file = fs.file(_consolidatedPath);
    if (!await file.exists()) return null;
    try {
      return DateTime.tryParse((await file.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  /// The stamp a finished consolidation pass leaves behind: the next one is an
  /// interval away. Written through a rename, the way the index is.
  Future<void> stampConsolidated(DateTime at) async {
    final directory = fs.directory(dir);
    if (!await directory.exists()) await directory.create(recursive: true);
    await _writer.write(_consolidatedPath, at.toUtc().toIso8601String());
  }

  /// The maintenance half of the store: the ops a model reports after it has
  /// been shown the memories — drops, replacements, and new ones. An
  /// operation on an id that is not there is ignored, and a replacement of a
  /// missing id lands as a new memory rather than a record with a made-up id,
  /// so a model that misremembers a name costs nothing. Returns what landed.
  Future<({int added, int updated, int deleted})> maintain({
    List<String>? delete,
    Map<String, String>? replaces,
    List<String>? add,
    String? chat,
  }) async {
    final live = {for (final entry in await entries()) entry.id: entry};
    var added = 0;
    var updated = 0;
    var deleted = 0;
    for (final id in delete ?? const <String>[]) {
      if (!live.containsKey(id)) continue;
      await _append(_marker("d", id));
      deleted++;
    }
    for (final entry in (replaces ?? const <String, String>{}).entries) {
      final id = entry.key;
      final text = entry.value;
      if (text.trim().isEmpty) continue;
      final when = DateTime.now().toUtc();
      if (live.containsKey(id)) {
        await _append(_memoryRecord(id, text.trim(), when, chat));
        updated++;
      } else {
        await _append(_memoryRecord(const Uuid().v4(), text.trim(), when, chat));
        added++;
      }
    }
    for (final text in add ?? const <String>[]) {
      if (text.trim().isEmpty) continue;
      await _append(_memoryRecord(const Uuid().v4(), text.trim(),
          DateTime.now().toUtc(), chat));
      added++;
    }
    if (added + updated + deleted > 0) await _rebuildIndex();
    return (added: added, updated: updated, deleted: deleted);
  }

  String _memoryRecord(String id, String text, DateTime at, String? chat) =>
      jsonEncode({
        "t": "m",
        "id": id,
        "text": text,
        "at": at.toIso8601String(),
        "chat": ?chat,
      });

  /// The memories [query] is about: the ones that clear [recallMinScore],
  /// best first, at most [recallLimit]. [entries] spares the log a second read
  /// where the caller has it in hand already.
  @override
  Future<List<MemoryEntry>> search(
    String query, {
    List<MemoryEntry>? entries,
  }) async {
    final all = entries ?? await this.entries();
    if (all.isEmpty) return const [];
    final index = await _index(all);
    final scores = <String, double>{};
    for (final term in {...tokenize(query)}) {
      final ids = index[term];
      if (ids == null || ids.isEmpty) continue;
      final share = 1 / ids.length;
      for (final id in ids) {
        scores[id] = (scores[id] ?? 0) + share;
      }
    }
    final hits = <(MemoryEntry, double)>[
      for (final entry in all)
        if (scores[entry.id] != null) (entry, scores[entry.id]!),
    ];
    hits.sort((a, b) =>
        b.$2 == a.$2 ? b.$1.at.compareTo(a.$1.at) : b.$2.compareTo(a.$2));
    // [hits] is best first, so the bar and the cap are both a cut point.
    final kept = <MemoryEntry>[];
    for (final hit in hits) {
      if (hit.$2 < recallMinScore) break;
      kept.add(hit.$1);
      if (kept.length == recallLimit) break;
    }
    return kept;
  }

  Future<String> _readLog() async {
    final file = fs.file(_logPath);
    return await file.exists() ? file.readAsString() : "";
  }

  Future<void> _append(String line) async {
    final directory = fs.directory(dir);
    if (!await directory.exists()) await directory.create(recursive: true);
    await fs.file(_logPath).writeAsString("$line\n", mode: FileMode.append);
  }

  /// The replay: the last record for an id stands, a tombstone after a memory
  /// removes it, and the first line that will not parse ends the read —
  /// appends are ordered, so it is the one a kill landed in.
  List<MemoryEntry> _replay(String log) {
    final latest = <String, MemoryEntry>{};
    final deleted = <String>{};
    final pinned = <String, bool>{};
    for (final line in log.split("\n")) {
      if (line.trim().isEmpty) continue;
      final record = _recordOf(line);
      if (record == null) break;
      if (record.delete) {
        deleted.add(record.id);
      } else if (record.pin != null) {
        pinned[record.id] = record.pin!;
      } else {
        // A reassigned key keeps its first place: an update stays put.
        final memory = record.entry!;
        latest[memory.id] = memory;
      }
    }
    return [
      for (final entry in latest.values)
        if (!deleted.contains(entry.id))
          entry.copyWithPinned(pinned[entry.id] ?? false),
    ];
  }

  /// One line of the log, or null where it is not a record at all: a torn
  /// write, or one whose fields are not what the reader needs.
  ({bool delete, bool? pin, String id, MemoryEntry? entry})? _recordOf(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final id = decoded["id"];
    if (id is! String) return null;
    if (decoded["t"] == "d") {
      return (delete: true, pin: null, id: id, entry: null);
    }
    if (decoded["t"] == "p" || decoded["t"] == "u") {
      return (delete: false, pin: decoded["t"] == "p", id: id, entry: null);
    }
    if (decoded["t"] != "m") return null;
    final text = decoded["text"];
    final at = decoded["at"];
    if (text is! String || at is! String) return null;
    final when = DateTime.tryParse(at);
    if (when == null) return null;
    final chat = decoded["chat"];
    return (
      delete: false,
      pin: null,
      id: id,
      entry: MemoryEntry(
        id: id,
        text: text,
        at: when,
        chat: chat is String ? chat : null,
      ),
    );
  }

  /// The index, rebuilt where it is missing or the log has moved on from the
  /// size it was built at.
  Future<Map<String, List<String>>> _index(List<MemoryEntry> entries) async {
    final indexFile = fs.file(_indexPath);
    final logFile = fs.file(_logPath);
    final logSize = await logFile.exists() ? (await logFile.stat()).size : 0;
    if (await indexFile.exists()) {
      try {
        final json = jsonDecode(await indexFile.readAsString());
        if (json is Map && json["size"] == logSize) {
          final terms = json["terms"];
          if (terms is Map) {
            return {
              for (final term in terms.entries)
                term.key as String: [
                  for (final id in (term.value as List)) id as String,
                ],
            };
          }
        }
      } catch (_) {
        // A broken index is rebuilt, for the reason the store exists.
      }
    }
    final built = _indexFor(entries);
    await _writeIndex(logSize, built);
    return built;
  }

  Future<void> _rebuildIndex() async {
    final all = await entries();
    final logFile = fs.file(_logPath);
    final size = await logFile.exists() ? (await logFile.stat()).size : 0;
    await _writeIndex(size, _indexFor(all));
  }

  Future<void> _writeIndex(int size, Map<String, List<String>> terms) async {
    // Through a rename: a torn index would cost a rebuild on the next read,
    // but a reader must never see an empty one under a non-empty log.
    await _writer.write(
        _indexPath, jsonEncode({"size": size, "terms": terms}));
  }

  static Map<String, List<String>> _indexFor(List<MemoryEntry> entries) {
    final terms = <String, List<String>>{};
    for (final entry in entries) {
      for (final term in {...tokenize(entry.text)}) {
        terms.putIfAbsent(term, () => []).add(entry.id);
      }
    }
    return terms;
  }
}

/// The words the index and the query share: lowercased runs of letters and
/// digits, two or more long. Nothing fancier — the store is hundreds of
/// entries, not a corpus.
List<String> tokenize(String text) {
  final words = <String>[];
  for (final match in RegExp(r"[a-z0-9]+").allMatches(text.toLowerCase())) {
    final word = match.group(0)!;
    if (word.length >= 2) words.add(word);
  }
  return words;
}

/// The memories as a block of prompt text, newest first, one line each with
/// the caps applied. This is the always-loaded half of the store: what is not
/// in the line is still there, and the line says the search can reach it.
/// Empty where there is nothing, so the caller sends no section then.
String renderIndex(List<MemoryEntry> memories) {
  if (memories.isEmpty) return "";
  final lines = <String>[];
  var total = 0;
  for (final memory in [...memories].reversed) {
    var text = memory.text.trim();
    if (text.length > indexEntryChars) {
      text = "${text.substring(0, indexEntryChars)}...";
    }
    lines.add("- $text");
    total += text.length + 2;
    if (total > indexBlockChars) break;
  }
  return lines.join("\n");
}

/// The memories as a block of prompt text, the caps applied. Empty where
/// there is nothing, so the caller sends no section then. [withIds] is the
/// tool's rendering: the ids the update and delete tools take, which the
/// prompt's own recall does not need.
String renderRecall(List<MemoryEntry> memories, {bool withIds = false}) {
  if (memories.isEmpty) return "";
  final lines = <String>[];
  var total = 0;
  for (final memory in memories) {
    var text = memory.text.trim();
    if (text.length > recallEntryChars) {
      text = "${text.substring(0, recallEntryChars)}...";
    }
    final line = withIds ? "- [${memory.id}] $text" : "- $text";
    lines.add(line);
    total += line.length + 1;
    if (total > recallBlockChars) break;
  }
  return lines.join("\n");
}

/// The pinned memories as a block: their full text, newest first, cut at
/// [pinnedLimit]. The cap is the prompt's, not the store's: a store that grew
/// past it keeps the pins, and the newest four are the ones a pin means
/// most.
String renderPinned(List<MemoryEntry> memories) {
  final pinned = memories.where((m) => m.pinned).toList()
    ..sort((a, b) => b.at.compareTo(a.at));
  return pinned
      .take(pinnedLimit)
      .map((memory) => "- ${memory.text.trim()}")
      .join("\n");
}

/// The whole store as the consolidation pass's question: every entry in full
/// with its id, newest first, cut at [consolidationMaxEntries]. The recall
/// caps do not apply — the pass decides over the whole store, and a fact cut
/// to a line is a fact it cannot judge.
String renderConsolidation(List<MemoryEntry> memories) {
  if (memories.isEmpty) return "";
  return memories
      .reversed
      .take(consolidationMaxEntries)
      .map((memory) => "- [${memory.id}] ${memory.text.trim()}")
      .join("\n");
}
