import "dart:async";
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
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

  /// Restores the longest of [keys] (a request's prefix keys, longest first)
  /// that has a file into [instance] before a turn, unless it already holds at
  /// least that much — a continuation of the same chat, which its live state
  /// serves.
  ///
  /// True when the instance ends up holding one of [keys], however it got
  /// there. A turn ignores it — it sends the prompt either way — but the
  /// prefill does not: a hit is the whole of what its warm-up was going to do.
  Future<bool> warm(
    LocalInstance instance, {
    required String namespace,
    required List<String> keys,
  }) async {
    final candidate = _longestSaved(namespace, keys);
    if (candidate == null) return false;
    // Restoring a shorter or equal file would only throw progress away.
    final live = _live[instance];
    if (live != null && _upto(keys, live) >= _upto(keys, candidate)) {
      return true;
    }
    if (!await instance.restoreState(promptFilename(namespace, candidate))) {
      return false;
    }
    _live[instance] = candidate;
    await _touch(namespace, candidate);
    return true;
  }

  /// Saves [instance]'s state after a turn under [key], then evicts down to
  /// [count] files of this namespace and under the disk budget. A turn passes
  /// the whole prompt's key (`keys.first`); the prefill passes the body's
  /// (`keys.last`), so the warmed body survives a reload and every chat's
  /// [warm] finds it.
  Future<void> keep(
    LocalInstance instance, {
    required String namespace,
    required String key,
    required int count,
  }) async {
    if (_saved[instance] == key) return;
    if (!await instance.saveState(promptFilename(namespace, key))) return;
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
      await File(
        p.join(dir, promptFilename(namespace, key)),
      ).setLastModified(DateTime.now());
    } catch (_) {}
  }

  String? _longestSaved(String namespace, List<String> keys) {
    for (final key in keys) {
      if (File(p.join(dir, promptFilename(namespace, key))).existsSync()) {
        return key;
      }
    }
    return null;
  }

  /// How much of the prefix a key covers, as its position in the
  /// longest-first list read as a length. A key not in the list is -1 — a
  /// different chat, which is cold state to restore into.
  int _upto(List<String> keys, String key) {
    final i = keys.indexOf(key);
    return i < 0 ? -1 : keys.length - i;
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

/// What a request needs to reach the cache with: which instance's files, under
/// which namespace, and which prefixes to look for.
typedef PromptLookup = ({String namespace, List<String> keys});

/// The one derivation of that, so the turn that saves a file and the warm-up
/// that reads it cannot disagree about where it is. Null where there is
/// nothing to look for: the setting off, or a request with no messages.
PromptLookup? promptLookup({
  required LocalInstance instance,
  required LocalOptions options,
  required List<LlmMessage> messages,
  required List<LlmTool> tools,
}) {
  if (!options.keepsPrompts) return null;
  final keys = promptPrefixKeys(messages, tools);
  if (keys.isEmpty) return null;
  return (
    // Over the context it actually loaded with rather than the one asked for,
    // so a file is never filed under a size nothing serves.
    namespace: promptNamespace(
      modelId: instance.model.id,
      contextLength: instance.load.contextLength,
      device: options.device,
    ),
    keys: keys,
  );
}

/// The namespace a file belongs to: everything that makes one model's state
/// unreadable by another. A change to any of these is invalidation, done by the
/// file landing under a name nothing looks for rather than by dropping files.
/// `q8` is the fixed KV quant llama.cpp runs with when caching is on, named so
/// that turning the cache off (f16) and on again cannot cross-load a file.
///
/// The device is the picker's word rather than the resolved one, so Auto and
/// CPU keep separate files where they load the same way.
///
/// The separator is a NUL, written as an escape rather than as the byte: a
/// device name cannot contain one, so no two readings of these fields can hash
/// alike — and the source file stays text.
String promptNamespace({
  required String modelId,
  required int contextLength,
  String? device,
}) => _hash(
  "$modelId\u0000$contextLength\u0000${device ?? ''}\u0000q8",
).substring(0, 16);

/// One key per message boundary of [messages], longest prefix first, each over
/// that prefix plus the [tools] that head every request. The longest is the
/// whole conversation — an exact reopen — and the shortest is the system+tools
/// body the prefill warms; anything between is a continuation caught
/// mid-history.
List<String> promptPrefixKeys(List<LlmMessage> messages, List<LlmTool> tools) {
  final buffer = StringBuffer(_encodeTools(tools));
  final atBoundary = <String>[];
  for (final message in messages) {
    buffer.write(_encodeMessage(message));
    atBoundary.add(_hash(buffer.toString()));
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

/// The filename for a namespace and a key. Flat — llama.cpp's
/// `--slot-save-path` takes a basename, so the namespace rides in the name.
String promptFilename(String namespace, String key) => "$namespace.$key.bin";

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
