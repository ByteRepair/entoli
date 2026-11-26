import "dart:async";
import "dart:convert";

import "package:file/file.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:entoli_core/model/documents.dart";
import "package:entoli_core/model/file_errors.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/sync/protocol.dart";
import "package:entoli_core/model/sync/settings_merge.dart";

/// The settings a device keeps in step with its peers: read as items, and
/// written back from what a merge made. The port the container binds, over
/// the settings and the secret store; a test's is a map.
abstract interface class SyncedSettings {
  /// The profile and every provider, a provider's stored key among its
  /// fields.
  SyncedItems read();

  /// Makes these the settings: an item that is null or missing from [items]
  /// is not kept.
  Future<void> write(SyncedItems items);
}

/// The end of a connection settings are offered over: a `LivePeer`, or a
/// test's.
abstract interface class SettingsPeer {
  String get deviceId;
  Future<void> send(SyncMessage message);
}

/// What one pair has settled about its settings, kept per peer: who wins a
/// conflict, what the two last agreed, and what this device last offered.
class SettingsPairState {
  SettingsPairState({this.precedence, this.base, this.sent});

  SyncPrecedence? precedence;
  MergeBase? base;

  /// What this device's last offer held, which a reply is merged against:
  /// an edit made since it went is this device's, and kept.
  MergeBase? sent;

  Map<String, Object?> toJson() => {
    "precedence": ?precedence?.toJson(),
    "base": ?base?.toJson(),
    "sent": ?sent?.toJson(),
  };

  static SettingsPairState fromJson(Object? json) => json is Map
      ? SettingsPairState(
          precedence: SyncPrecedence.fromJson(json["precedence"]),
          base: MergeBase.fromJson(json["base"]),
          sent: MergeBase.fromJson(json["sent"]),
        )
      : SettingsPairState();
}

/// Where each pair's [SettingsPairState] is kept.
abstract interface class SettingsLedger {
  Future<SettingsPairState> read(String peerId);
  Future<void> write(String peerId, SettingsPairState state);
  Future<void> forget(String peerId);
}

/// One JSON file per peer under [directory]: `sync/settings/<id>.json`,
/// beside the registry and out of every backup with it. It holds hashes, not
/// keys, so nothing secret is in it.
class FileSettingsLedger implements SettingsLedger {
  FileSettingsLedger(this._fs, this.directory) : _writer = RenameWriter(_fs);

  final FileSystem _fs;
  final RenameWriter _writer;
  final String directory;

  String _path(String peerId) => p.join(directory, "$peerId.json");

  @override
  Future<SettingsPairState> read(String peerId) async {
    try {
      final text = await _fs.file(_path(peerId)).readAsString();
      return SettingsPairState.fromJson(jsonDecode(text));
    } on FileSystemException catch (e) {
      if (!e.isNotFound) rethrow;
      return SettingsPairState();
    } on FormatException catch (e) {
      logFailure("sync", "settings state for $peerId would not parse", e);
      return SettingsPairState();
    }
  }

  @override
  Future<void> write(String peerId, SettingsPairState state) async {
    await _fs.directory(directory).create(recursive: true);
    await _writer.write(_path(peerId), jsonEncode(state.toJson()));
  }

  @override
  Future<void> forget(String peerId) async {
    final file = _fs.file(_path(peerId));
    if (file.existsSync()) await file.delete();
  }
}

/// A pair's profile and providers kept in step: each device offers its
/// items, the other merges them with its own against what the two last
/// agreed ([mergeSettings]) and answers with the result, which both then
/// hold. The latest edit wins; only where both changed the same field does
/// the pair's [SyncPrecedence] decide, and until it has been chosen —
/// [undecided] is the peers waiting on it — nothing is sent but the
/// question.
class SettingsSync {
  SettingsSync({
    required this.selfId,
    required this.ledger,
    Future<DateTime?> Function(String peerId)? pairedAt,
  }) : _pairedAt = pairedAt ?? ((_) async => null);

  final String selfId;
  final SettingsLedger ledger;

  /// When the pair was made, which a choice the peer sends must postdate: one
  /// from before it is the last pairing's, which this device has forgotten.
  final Future<DateTime?> Function(String peerId) _pairedAt;

  /// Bound by the container once the settings can be read; null until then,
  /// which offers nothing and merges nothing.
  SyncedSettings? settings;

  /// The connected peers no precedence has been chosen with yet.
  final undecided = ValueNotifier<Set<String>>(const {});

  /// Each known pair's precedence, for the paired device's page.
  final precedences = ValueNotifier<Map<String, SyncPrecedence?>>(const {});

  final _live = <String, SettingsPeer>{};

  /// The peers an offer has gone to and not been answered: a second offer
  /// while one is out would move what its reply is merged against, so
  /// edits wait for the reply, which offers them.
  final _awaiting = <String>{};

  /// Every message of a pair is handled in turn, so one merge's write is in
  /// before the next reads.
  final _queues = <String, Future<void>>{};

  /// [work] after the pair's earlier work; its failure is the caller's, and
  /// logged.
  Future<void> _serial(String peerId, Future<void> Function() work) {
    final next = (_queues[peerId] ?? Future.value()).then((_) => work());
    _queues[peerId] = next.catchError((Object e) {
      logFailure("sync", "keeping settings in step with $peerId failed", e);
    });
    return next;
  }

  Future<SettingsPairState> _state(String peerId) async {
    final state = await ledger.read(peerId);
    _show(peerId, state.precedence);
    return state;
  }

  void _show(String peerId, SyncPrecedence? precedence) {
    if (precedences.value[peerId] != precedence ||
        !precedences.value.containsKey(peerId)) {
      precedences.value = {...precedences.value, peerId: precedence};
    }
    final waiting = precedence == null && _live.containsKey(peerId);
    if (waiting != undecided.value.contains(peerId)) {
      final next = {...undecided.value};
      waiting ? next.add(peerId) : next.remove(peerId);
      undecided.value = next;
    }
  }

  /// [peerId]'s choice, read for a page that shows it while the pair is not
  /// connected.
  Future<void> recall(String peerId) async {
    if (precedences.value.containsKey(peerId)) return;
    await _serial(peerId, () => _state(peerId));
  }

  /// [peer] is up: it is told what this device has, or asked to choose.
  Future<void> greet(SettingsPeer peer) {
    _live[peer.deviceId] = peer;
    return _serial(peer.deviceId, () async {
      final state = await _state(peer.deviceId);
      await _offer(peer, state);
    });
  }

  void gone(String peerId) {
    _live.remove(peerId);
    _awaiting.remove(peerId);
    _show(peerId, precedences.value[peerId]);
  }

  /// The pair's precedence chosen here, now: [winner] is a device's id, or
  /// null for the two not syncing these.
  Future<void> choose(String peerId, String? winner) =>
      _serial(peerId, () async {
        final state = await ledger.read(peerId);
        _decided(
          state,
          SyncPrecedence(winner: winner, decidedAt: DateTime.now().toUtc()),
        );
        await ledger.write(peerId, state);
        _show(peerId, state.precedence);
        if (_live[peerId] case final peer?) await _offer(peer, state);
      });

  /// The pair is unpaired: what it settled goes with it.
  Future<void> forget(String peerId) => _serial(peerId, () async {
    await ledger.forget(peerId);
    precedences.value = {...precedences.value}..remove(peerId);
    gone(peerId);
  });

  /// This device's settings changed: each synced peer that does not hold
  /// them yet is offered them.
  void changed() {
    for (final peer in _live.values) {
      unawaited(
        _serial(peer.deviceId, () async {
          final state = await ledger.read(peer.deviceId);
          final items = settings?.read();
          if (items == null || !(state.precedence?.syncs ?? false)) return;
          if (_agrees(state.base, items)) return;
          if (_awaiting.contains(peer.deviceId)) return;
          await _offer(peer, state);
        }),
      );
    }
  }

  /// [precedence] made the pair's. A new choice is which settings to keep,
  /// as at a first sync, so what was agreed under the old one goes.
  static void _decided(SettingsPairState state, SyncPrecedence? precedence) {
    if (precedence == state.precedence) return;
    state
      ..precedence = precedence
      ..base = null
      ..sent = null;
  }

  static bool _agrees(MergeBase? base, SyncedItems items) =>
      base != null &&
      MergeBase.hashOf(base.items) ==
          MergeBase.hashOf(MergeBase.of(_present(items)).items);

  static SyncedItems _present(SyncedItems items) => {
    for (final MapEntry(:key, :value) in items.entries) key: ?value,
  };

  /// What this device has, and its precedence; the items only where the
  /// pair syncs them.
  Future<void> _offer(SettingsPeer peer, SettingsPairState state) async {
    final syncs = state.precedence?.syncs ?? false;
    final read = settings?.read();
    // Nothing to read is not nothing held: an empty offer would take the
    // peer's settings away.
    if (syncs && read == null) return;
    final items = syncs
        ? _present(read!)
        : const <String, Map<String, Object?>?>{};
    if (syncs) {
      state.sent = MergeBase.of(items);
      await ledger.write(peer.deviceId, state);
      _awaiting.add(peer.deviceId);
    }
    await peer.send(
      SyncMessage.settingsOffer(
        items: items,
        precedence: state.precedence?.toJson(),
      ),
    );
  }

  /// An offer or a reply from [peer].
  Future<void> received(SettingsPeer peer, SyncSettingsOffer offer) =>
      _serial(peer.deviceId, () async {
        final state = await ledger.read(peer.deviceId);
        if (offer.reply) _awaiting.remove(peer.deviceId);
        var theirs = SyncPrecedence.fromJson(offer.precedence);
        final paired = await _pairedAt(peer.deviceId);
        if (theirs != null &&
            paired != null &&
            theirs.decidedAt.isBefore(paired)) {
          theirs = null;
        }
        final precedence = SyncPrecedence.later(state.precedence, theirs);
        if (precedence != state.precedence) {
          _decided(state, precedence);
          await ledger.write(peer.deviceId, state);
        }
        _show(peer.deviceId, precedence);
        final synced = settings;
        if (precedence == null || !precedence.syncs || synced == null) {
          // Theirs is behind: they are told this device's.
          if (!offer.reply && theirs != precedence) {
            await peer.send(
              SyncMessage.settingsOffer(
                items: const {},
                precedence: precedence?.toJson(),
                reply: true,
              ),
            );
          }
          return;
        }
        // Their offer was made before they knew the pair syncs: this
        // device's goes to them instead.
        if (!(theirs?.syncs ?? false)) {
          if (!offer.reply) await _offer(peer, state);
          return;
        }
        final local = synced.read();
        final remote = _present(offer.items);
        final localWins = precedence.winner == selfId;
        final merged = _present(
          mergeSettings(
            local: _present(local),
            remote: remote,
            base: offer.reply ? (state.sent ?? state.base) : state.base,
            localWins: localWins,
          ),
        );
        if (!sameItems(merged, _present(local))) await synced.write(merged);
        if (offer.reply) {
          state.base = MergeBase.of(remote);
          await ledger.write(peer.deviceId, state);
          // An edit made here since the offer went is this device's still.
          if (!sameItems(merged, remote)) await _offer(peer, state);
          return;
        }
        state.base = MergeBase.of(merged);
        state.sent = state.base;
        await ledger.write(peer.deviceId, state);
        await peer.send(
          SyncMessage.settingsOffer(
            items: merged,
            precedence: precedence.toJson(),
            reply: true,
          ),
        );
      });
}
