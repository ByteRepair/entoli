import "dart:convert";

import "package:crypto/crypto.dart";

import "../../../domain/local_llm.dart";
import "llm_client.dart";

/// Persists an on-device model's KV cache to disk so reopening a chat restores
/// it rather than reprocessing the whole history — minutes, on a phone.
///
/// **Content-addressed, and that is what keeps it the provider's own.** Nothing
/// hands it a chat id: it keys a dump on the prompt prefix that produced it, so
/// no identifier crosses `LlmClient.stream` and no interface a hosted provider
/// shares grew a method — the same bargain [LocalPrefill] makes. A rewound or
/// edited chat hashes to a different key, misses, and its stale dump ages out of
/// the LRU on its own, so there is no invalidation to write. It also subsumes
/// the prefill's body KV: the warmed system+tools prefix is just the shortest
/// key, saved by the same mechanism. See "Persisting the KV cache to disk" in
/// `lib/data/local/AGENTS.md`.
///
/// The concrete one is [FileKvCache], built on Android alone. Null everywhere
/// else, which is what leaves the pool client caching nothing.
abstract class LocalKvCache {
  /// Restore the longest of [keys] (a request's prefix keys, longest first) that
  /// has a dump into the server's slot before a turn, unless the live slot
  /// already holds at least that much — a continuation of the same chat, which
  /// the server's own cache serves. [keys] is [kvPrefixKeys] of the request,
  /// computed once by the caller so a turn hashes its prompt one time, not twice.
  ///
  /// True when the slot ends up holding one of [keys], however it got there. A
  /// turn ignores it — it sends the prompt either way — but [LocalPrefill] does
  /// not: a hit is the whole of what its warm-up was going to do, so it has
  /// nothing left to read.
  Future<bool> warm(
    LocalEndpoint at, {
    required String namespace,
    required List<String> keys,
  });

  /// Save the slot after a turn under [key], then evict down to [count] dumps of
  /// this namespace and under the disk budget. A turn passes the whole prompt's
  /// key (`keys.first`); the prefill passes the body's (`keys.last`), so the
  /// warmed body survives a reload and every chat's [warm] finds it — the
  /// physical dump holds a little more than the body, which the server trims when
  /// a real chat diverges from it.
  Future<void> keep(
    LocalEndpoint at, {
    required String namespace,
    required String key,
    required int count,
  });
}

/// The namespace a dump belongs to: everything that makes one model's KV
/// unreadable by another. A change to any of these is invalidation, done by the
/// dump landing under a name nothing looks for rather than by dropping files.
/// `q8` is the fixed KV quant the server runs with when caching is on, named so
/// that turning the cache off (f16) and on again cannot cross-load a dump.
///
/// The separator is a NUL, written as an escape rather than as the byte: a
/// device name cannot contain one, so no two readings of these fields can hash
/// alike — and the source file stays text, which with the byte in it, it is
/// not. Git calls it binary and shows no diff for any change to this file.
String kvNamespace({
  required String modelId,
  required int contextLength,
  String? device,
}) =>
    _hash("$modelId\u0000$contextLength\u0000${device ?? ''}\u0000q8")
        .substring(0, 16);

/// One key per message boundary of [messages], longest prefix first, each over
/// that prefix plus the [tools] that head every request. The longest is the
/// whole conversation — an exact reopen — and the shortest is the system+tools
/// body the prefill warms; anything between is a continuation caught mid-history.
List<String> kvPrefixKeys(List<LlmMessage> messages, List<LlmTool> tools) {
  final buffer = StringBuffer(_encodeTools(tools));
  final atBoundary = <String>[];
  for (final message in messages) {
    buffer.write(_encodeMessage(message));
    atBoundary.add(_hash(buffer.toString()));
  }
  // Longest first, and never the empty prefix — restoring the bare tools head
  // would evict a warmer slot to load almost nothing.
  return atBoundary.reversed.toList();
}

/// What a request needs to reach the cache with: where its dumps live and which
/// prefixes to look for. Null where there is nothing to look in — no cache on
/// this platform, the setting off, or a request with no messages to key on.
typedef KvLookup = ({LocalKvCache cache, String namespace, List<String> keys});

/// The one derivation of that, so the turn that saves a dump and the warm-up
/// that reads it cannot disagree about where it is — the bargain `poolOptions`
/// makes for the serve flags, made here for the name they are hashed into.
KvLookup? kvLookup(
  LocalKvCache? cache, {
  required bool on,
  required String modelId,
  required LocalEndpoint at,
  required String? device,
  required List<LlmMessage> messages,
  required List<LlmTool> tools,
}) {
  if (cache == null || !on) return null;
  final keys = kvPrefixKeys(messages, tools);
  if (keys.isEmpty) return null;
  return (
    cache: cache,
    // Over the context the server actually loaded with rather than the one that
    // was asked for, so a dump is never filed under a size nothing serves.
    namespace: kvNamespace(
      modelId: modelId,
      contextLength: at.contextLength,
      device: device,
    ),
    keys: keys,
  );
}

/// A dump on disk, as eviction sees it.
typedef KvFile = ({String name, int size, DateTime modified});

/// Which dumps to delete, given all of them and the budget. Two bounds: keep
/// only the newest [count] of the active [namespace], and — across every
/// namespace, so an abandoned model's dumps are reaped too — stay under
/// [budgetBytes] by dropping the globally oldest survivors.
///
/// Both bounds read [KvFile.modified] as when a dump was last *used*, which is
/// what [FileKvCache] keeps it as — see the touch on restore there. Left as the
/// write time it would reach the shared body dump first, that being the one
/// file written once and then read by every chat after it.
Set<String> kvEvictions(
  List<KvFile> files, {
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

/// The dump filename for a namespace and a key. Flat — the server's
/// `--slot-save-path` takes a basename, so the namespace rides in the name.
String kvFilename(String namespace, String key) => "$namespace.$key.bin";

String? _namespaceOf(String filename) {
  final dot = filename.indexOf(".");
  return dot < 0 ? null : filename.substring(0, dot);
}

String _hash(String input) => sha256.convert(utf8.encode(input)).toString();

String _encodeTools(List<LlmTool> tools) => jsonEncode([
      for (final tool in tools) {"n": tool.name, "d": tool.description, "s": tool.schema},
    ]);

/// Deterministic, and only the fields that reach the rendered prompt — so the
/// same conversation always hashes the same across a reload, and two different
/// ones do not collide. Attachment bytes are named by length rather than hashed:
/// a dump that turns out not to be a real token-prefix is caught and reprocessed
/// by the server, so the key only has to be stable, not exact.
String _encodeMessage(LlmMessage m) => jsonEncode({
      "r": m.role.index,
      "t": m.text,
      if (m.reasoning != null) "th": m.reasoning,
      if (m.toolCallId != null) "ti": m.toolCallId,
      if (m.toolCalls.isNotEmpty)
        "c": [
          for (final c in m.toolCalls) {"i": c.id, "n": c.name, "a": c.argumentsJson},
        ],
      if (m.attachments.isNotEmpty)
        "at": [
          for (final a in m.attachments)
            {"f": a.filename, "m": a.mimeType, "l": a.bytes.length},
        ],
    });
