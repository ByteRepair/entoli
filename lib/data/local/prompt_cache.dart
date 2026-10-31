import "dart:async";
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart" show visibleForTesting;
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../builtin/llm/llm_client.dart";
import "local_instance.dart";

/// A loaded model's prompt state, kept on disk so reopening a chat restores it
/// rather than reading the whole history again — minutes, on a phone. Each
/// runtime writes its own kind of file ([LocalInstance.saveState]); which file,
/// when, and which to throw away is decided here, once for every runtime.
///
/// **Content-addressed, and that is what keeps it the provider's own.** Nothing
/// hands it a chat id: it keys a file on the prompt prefix that produced it, so
/// no identifier crosses `LlmClient.stream` and no interface a hosted provider
/// shares grew a method. A rewound or edited chat hashes to a different key,
/// misses, and its stale file ages out of the LRU on its own, so there is no
/// invalidation to write. It also subsumes the prefill's: the warmed
/// system+tools prefix is just the shortest key. See "Persisting the KV cache
/// to disk" in `lib/data/local/AGENTS.md`.
class PromptCache {
  PromptCache(this.dir) {
    // A runtime may be told this directory at launch and not create it, so it
    // has to exist before the first turn. One `mkdir`, so synchronously at
    // startup is cheaper than a guard on every save.
    Directory(dir).createSync(recursive: true);
  }

  /// One directory for every model: the namespace rides in each file's name.
  final String dir;

  /// The longest key known to be in each instance's live state, so a
  /// continuation is not made to restore what the instance already holds.
  final _live = Expando<String>();

  /// The last key saved from each instance, so an unchanged prompt is not
  /// written twice.
  final _saved = Expando<String>();

  /// Beyond the per-namespace count, a ceiling on the whole directory so an
  /// abandoned model's files cannot fill the disk. Generous — the count is the
  /// bound that usually bites; this is the one that reaps what the count does
  /// not see.
  static const _budgetBytes = 4 * 1024 * 1024 * 1024;

  /// Where [messages] and [tools] would be kept for [instance], or null
  /// where nothing is looked for: the setting off, or a request with no
  /// messages. The turn and the prefill both reach the cache through this, so
  /// the one that saves a file and the one that reads it cannot disagree about
  /// where it is.
  PromptEntry? lookup(
    LocalInstance instance,
    LocalOptions options,
    List<LlmMessage> messages,
    List<LlmTool> tools,
  ) {
    if (!options.keepsPrompts) return null;
    final keys = promptPrefixKeys(messages, tools);
    if (keys.isEmpty) return null;
    return PromptEntry._(this, instance, keys, options.keptPrompts);
  }

  /// The file [key] of [instance]'s is kept in.
  @visibleForTesting
  String fileOf(LocalInstance instance, String key) =>
      _file(_namespaceFor(instance), key);

  String _file(String namespace, String key) =>
      p.join(dir, "$namespace.$key.bin");

  /// The namespace a file belongs to: everything that makes one model's state
  /// unreadable by another, as the instance says
  /// ([LocalInstance.stateNamespace]). A change to any of it is invalidation,
  /// done by the file landing under a name nothing looks for rather than by
  /// dropping files.
  static String _namespaceFor(LocalInstance instance) =>
      _hash(instance.stateNamespace).substring(0, 16);

  Future<bool> _warm(LocalInstance instance, List<String> keys) async {
    final namespace = _namespaceFor(instance);
    // Restoring a shorter or equal file would only throw progress away, so
    // only the keys longer than the live one are looked for on disk — which
    // mid-turn is none of the history, rather than a stat per message.
    final live = _live[instance];
    final liveAt = live == null ? -1 : keys.indexOf(live);
    final candidate = _longestSaved(
      namespace,
      liveAt < 0 ? keys : keys.take(liveAt),
    );
    if (candidate == null) return liveAt >= 0;
    if (!await instance.restoreState(_file(namespace, candidate))) {
      return false;
    }
    _live[instance] = candidate;
    await _touch(namespace, candidate);
    return true;
  }

  Future<void> _keep(LocalInstance instance, String key, int count) async {
    if (_saved[instance] == key) return;
    final namespace = _namespaceFor(instance);
    if (!await instance.saveState(_file(namespace, key))) return;
    _saved[instance] = key;
    // The instance now holds this prefix (and, for a real turn, the reply
    // after it), so it is what a continuation reuses without a restore.
    _live[instance] = key;
    // Cleanup, not correctness — nothing waits on it, so it does not gate the
    // turn's completion behind a directory listing.
    unawaited(_evict(namespace, count));
  }

  /// What makes [promptEvictions] an LRU rather than a first-in-first-out: a
  /// file's date is when it was last restored, not when it was written. The
  /// body every chat starts from is written once by the prefill and read
  /// forever after, so on write order it is the oldest file within a chat or
  /// two and both bounds reap it first — the one file they should reach last.
  Future<void> _touch(String namespace, String key) async {
    try {
      await File(_file(namespace, key)).setLastModified(DateTime.now());
    } catch (_) {}
  }

  String? _longestSaved(String namespace, Iterable<String> keys) {
    for (final key in keys) {
      if (File(_file(namespace, key)).existsSync()) {
        return key;
      }
    }
    return null;
  }

  /// Nobody awaits it, so nothing it throws has anywhere to go: a directory
  /// that will not list is a pass that did not happen, said once.
  Future<void> _evict(String namespace, int count) async {
    final files = <PromptFile>[];
    final names = <String>[];
    try {
      await for (final entry in Directory(dir).list()) {
        if (entry is! File) continue;
        names.add(p.basename(entry.path));
        if (!entry.path.endsWith(".bin")) continue;
        final stat = entry.statSync();
        files.add((
          name: p.basename(entry.path),
          size: stat.size,
          modified: stat.modified,
        ));
      }
    } on FileSystemException catch (e) {
      logFailure("prompt-cache", "eviction could not list", e.message);
      return;
    }
    for (final name in promptEvictions(
      files,
      namespace: namespace,
      count: count,
      budgetBytes: _budgetBytes,
    )) {
      // A runtime may keep what a state file covers beside it, under the
      // same name and more — MLX's `<file>.json` — which goes with it.
      for (final file in [
        name,
        ...names.where((n) => n.startsWith("$name.")),
      ]) {
        try {
          await File(p.join(dir, file)).delete();
        } catch (_) {}
      }
    }
  }
}

/// One request's place in a [PromptCache]: its instance and its prefix keys,
/// longest first. Best-effort throughout — a cache that will not answer is a
/// prompt read the way it was before there was one, never a broken turn.
class PromptEntry {
  PromptEntry._(this._cache, this._instance, this._keys, this._count);

  final PromptCache _cache;
  final LocalInstance _instance;
  final List<String> _keys;

  /// How many files of this namespace to keep.
  final int _count;

  /// Restores the longest saved prefix into the instance, unless it already
  /// holds at least that much — a continuation of the same chat, which its
  /// live state serves.
  ///
  /// True when the instance ends up holding one of the prefixes, however it
  /// got there. A turn ignores it — it sends the prompt either way — but the
  /// prefill does not: a hit is the whole of what its warm-up was going to do.
  Future<bool> warm() async {
    try {
      return await _cache._warm(_instance, _keys);
    } catch (e) {
      logFailure("prompt-cache", "restore failed", e);
      return false;
    }
  }

  /// Saves the instance's state after a turn under the whole prompt's key,
  /// then evicts down to the count and under the disk budget.
  Future<void> keep() => _keepAs(_keys.first);

  /// Saves it under the body's key — the system message and tools every chat
  /// shares — so a warmed body survives a reload and every chat's [warm]
  /// finds it.
  Future<void> keepBody() => _keepAs(_keys.last);

  Future<void> _keepAs(String key) async {
    try {
      await _cache._keep(_instance, key, _count);
    } catch (e) {
      logFailure("prompt-cache", "save failed", e);
    }
  }
}

/// One key per message boundary of [messages], longest prefix first, each over
/// that prefix plus the [tools] that head every request. The longest is the
/// whole conversation — an exact reopen — and the shortest is the system+tools
/// body the prefill warms; anything between is a continuation caught
/// mid-history.
///
/// Chained rather than each over its whole prefix: a key is the hash of the
/// key before it and its own message, which identifies the same prefix and
/// costs one pass over the conversation rather than one per message.
List<String> promptPrefixKeys(List<LlmMessage> messages, List<LlmTool> tools) {
  var key = _hash(_encodeTools(tools));
  final atBoundary = <String>[];
  for (final message in messages) {
    key = _hash("$key${_encodeMessage(message)}");
    atBoundary.add(key);
  }
  // Longest first, and never the empty prefix — restoring the bare tools head
  // would throw away warmer state to load almost nothing.
  return atBoundary.reversed.toList();
}

/// A file on disk, as eviction sees it.
typedef PromptFile = ({String name, int size, DateTime modified});

/// Which files to delete, given all of them and the budget. Two bounds: keep
/// only the newest [count] of the active [namespace], and — across every
/// namespace, so an abandoned model's files are reaped too — stay under
/// [budgetBytes] by dropping the globally oldest survivors. Both read
/// [PromptFile.modified] as when a file was last *used*; see the touch on
/// restore in [PromptCache].
Set<String> promptEvictions(
  List<PromptFile> files, {
  required String namespace,
  required int count,
  required int budgetBytes,
}) {
  final doomed = <String>{};
  final mine = files.where((f) => _namespaceOf(f.name) == namespace).toList()
    ..sort((a, b) => b.modified.compareTo(a.modified));
  for (final old in mine.skip(count)) {
    doomed.add(old.name);
  }

  final survivors = files.where((f) => !doomed.contains(f.name)).toList()
    ..sort((a, b) => a.modified.compareTo(b.modified));
  var total = survivors.fold<int>(0, (sum, f) => sum + f.size);
  for (final oldest in survivors) {
    if (total <= budgetBytes) break;
    doomed.add(oldest.name);
    total -= oldest.size;
  }
  return doomed;
}

String? _namespaceOf(String filename) {
  final dot = filename.indexOf(".");
  return dot < 0 ? null : filename.substring(0, dot);
}

String _hash(String input) => sha256.convert(utf8.encode(input)).toString();

String _encodeTools(List<LlmTool> tools) => jsonEncode([
  for (final tool in tools)
    {"n": tool.name, "d": tool.description, "s": tool.schema},
]);

/// Deterministic, and only the fields that reach the rendered prompt — so the
/// same conversation always hashes the same across a reload, and two different
/// ones do not collide. Attachment bytes are named by length rather than
/// hashed: a file that turns out not to be a real token-prefix is caught and
/// reprocessed by the runtime, so the key only has to be stable, not exact.
String _encodeMessage(LlmMessage m) => jsonEncode({
  "r": m.role.index,
  "t": m.text,
  if (m.reasoning != null) "th": m.reasoning,
  if (m.toolCallId != null) "ti": m.toolCallId,
  if (m.toolCalls.isNotEmpty)
    "c": [
      for (final c in m.toolCalls)
        {"i": c.id, "n": c.name, "a": c.argumentsJson},
    ],
  if (m.attachments.isNotEmpty)
    "at": [
      for (final a in m.attachments)
        {"f": a.filename, "m": a.mimeType, "l": a.bytes.length},
    ],
});
