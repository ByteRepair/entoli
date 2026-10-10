import "dart:async";
import "dart:io";

import "package:http/http.dart" as http;

import "../../core/tls.dart";
import "package:path/path.dart" as p;

import "../../domain/local_llm.dart";
import "../builtin/llm/local_kv_cache.dart";
import "../../core/log.dart";

/// [LocalKvCache] over a directory and llama.cpp's slot save/restore. One
/// directory for every model — the dump's filename carries its namespace, and
/// `--slot-save-path` takes a basename, so nothing here is per-model but the
/// name it writes. The server this drives is the same one a turn reaches; these
/// are two more requests to it, at `/slots/0` rather than `/chat/completions`.
class FileKvCache implements LocalKvCache {
  FileKvCache(this._dir, {http.Client? client}) : _http = client ?? tlsClient() {
    // The server is launched with this as its `--slot-save-path` and will not
    // create it, so it has to exist before the first turn. Android only and a
    // single `mkdir`, so synchronously at startup is cheaper than a guard on
    // every save.
    Directory(_dir).createSync(recursive: true);
  }

  final String _dir;
  final http.Client _http;

  /// The longest key known to be in each endpoint's live slot, so a
  /// continuation is not made to restore what the running server already holds.
  final _live = <String, String>{};

  /// The last key saved for each endpoint, so an unchanged prompt is not written
  /// twice.
  final _saved = <String, String>{};

  /// Beyond the per-namespace count, a ceiling on the whole directory so an
  /// abandoned model's dumps cannot fill the disk. Generous — the count is the
  /// bound that usually bites; this is the one that reaps what the count does
  /// not see.
  static const _budgetBytes = 4 * 1024 * 1024 * 1024;

  @override
  Future<bool> warm(
    LocalEndpoint at, {
    required String namespace,
    required List<String> keys,
  }) async {
    final candidate = await _longestSaved(namespace, keys);
    if (candidate == null) return false;
    // Skip if the live slot already holds this much of the prefix: the server's
    // own longest-prefix cache serves a continuation, and restoring a shorter
    // or equal dump would only throw that progress away.
    final live = _live[at.baseUrl];
    if (live != null && _upto(keys, live) >= _upto(keys, candidate)) return true;
    if (!await _slot(at, "restore", kvFilename(namespace, candidate))) return false;
    _live[at.baseUrl] = candidate;
    await _touch(namespace, candidate);
    return true;
  }

  @override
  Future<void> keep(
    LocalEndpoint at, {
    required String namespace,
    required String key,
    required int count,
  }) async {
    if (_saved[at.baseUrl] == key) return;
    if (!await _slot(at, "save", kvFilename(namespace, key))) return;
    _saved[at.baseUrl] = key;
    // The slot now holds this prefix (and, for a real turn, the reply generated
    // after it), so it is what a continuation reuses without a restore.
    _live[at.baseUrl] = key;
    // Cleanup, not correctness — nothing waits on it, so it does not gate the
    // turn's completion behind a directory listing.
    unawaited(_evict(namespace, count));
  }

  /// What makes [kvEvictions] an LRU rather than a first-in-first-out: a dump's
  /// date is when it was last restored, not when it was written. The body every
  /// chat starts from is written once by the prefill and read forever after, so
  /// on write order it is the oldest file in the directory within a chat or two
  /// and both bounds reap it first — the one dump they should reach last.
  ///
  /// Best-effort, like everything else here: a filesystem that will not set it
  /// leaves the eviction order where it already was.
  Future<void> _touch(String namespace, String key) async {
    try {
      await File(p.join(_dir, kvFilename(namespace, key)))
          .setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// The longest of [keys] (already longest-first) with a dump on disk.
  Future<String?> _longestSaved(String namespace, List<String> keys) async {
    for (final key in keys) {
      if (await File(p.join(_dir, kvFilename(namespace, key))).exists()) return key;
    }
    return null;
  }

  /// How much of the prefix a key covers, as its position in the longest-first
  /// list read as a length. A key not in the list is -1 — a different chat,
  /// which is a cold slot to restore into.
  int _upto(List<String> keys, String key) {
    final i = keys.indexOf(key);
    return i < 0 ? -1 : keys.length - i;
  }

  Future<bool> _slot(LocalEndpoint at, String action, String filename) async {
    final root = Uri.parse(at.baseUrl).replace(path: "/slots/0", queryParameters: {"action": action});
    try {
      final response = await _http.post(
        root,
        headers: {
          "content-type": "application/json",
          if (at.apiKey.isNotEmpty) "authorization": "Bearer ${at.apiKey}",
        },
        body: '{"filename": "$filename"}',
      ).timeout(const Duration(seconds: 30));
      final ok = response.statusCode == 200;
      // A build without slot save/restore compiled in answers 501, and a
      // restore of a dump the current weights cannot read fails too — both are
      // a miss to fall back from, not a turn to break.
      if (!ok) logFailure("kv-cache", "$action refused", response.statusCode);
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> _evict(String namespace, int count) async {
    final files = <KvFile>[];
    await for (final entry in Directory(_dir).list()) {
      if (entry is! File || !entry.path.endsWith(".bin")) continue;
      final stat = await entry.stat();
      files.add((name: p.basename(entry.path), size: stat.size, modified: stat.modified));
    }
    for (final name in kvEvictions(files, namespace: namespace, count: count, budgetBytes: _budgetBytes)) {
      try {
        await File(p.join(_dir, name)).delete();
      } catch (_) {}
    }
  }
}
