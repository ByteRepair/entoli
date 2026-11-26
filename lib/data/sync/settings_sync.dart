import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
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
  FileSettingsLedger(this.directory);

  final String directory;

  File _file(String peerId) => File(p.join(directory, "$peerId.json"));

  @override
  Future<SettingsPairState> read(String peerId) async {
    final file = _file(peerId);
    try {
      return SettingsPairState.fromJson(jsonDecode(await file.readAsString()));
    } on PathNotFoundException {
      return SettingsPairState();
    } on FormatException catch (e) {
      logFailure("sync", "settings state for $peerId would not parse", e);
      return SettingsPairState();
    }
  }

  @override
  Future<void> write(String peerId, SettingsPairState state) async {
    final file = _file(peerId);
    await file.parent.create(recursive: true);
    final staged = File("${file.path}.tmp");
    await staged.writeAsString(jsonEncode(state.toJson()));
    await staged.rename(file.path);
  }

  @override
  Future<void> forget(String peerId) async {
    final file = _file(peerId);
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
  SettingsSync({required this.selfId, required this.ledger});

  final String selfId;
  final SettingsLedger ledger;

  /// Bound by the container once the settings can be read; null until then,
  /// which offers nothing and merges nothing.
  SyncedSettings? settings;

  /// The connected peers no precedence has been chosen with yet.
  final undecided = ValueNotifier<Set<String>>(const {});

  /// Each known pair's precedence, for the paired device's page.
  final precedences = ValueNotifier<Map<String, SyncPrecedence?>>(const {});

  final _live = <String, SettingsPeer>{};

  /// Every message of a pair is handled in turn, so one merge's write is in
  /// before the next reads.
  final _queues = <String, Future<void>>{};

  Future<void> _serial(String peerId, Future<void> Function() work) {
    final next = (_queues[peerId] ?? Future.value()).then((_) => work());
    _queues[peerId] = next.catchError((Object e) {
      logFailure("sync", "keeping settings in step with $peerId failed", e);
    });
    return _queues[peerId]!;
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
    _show(peerId, precedences.value[peerId]);
  }

  /// The pair's precedence chosen here, now: [winner] is a device's id, or
  /// null for the two not syncing these.
  Future<void> choose(String peerId, String? winner) =>
      _serial(peerId, () async {
        final state = await ledger.read(peerId);
        state.precedence = SyncPrecedence(
          winner: winner,
          decidedAt: DateTime.now().toUtc(),
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
          await _offer(peer, state);
        }),
      );
    }
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
        final theirs = SyncPrecedence.fromJson(offer.precedence);
        final precedence = SyncPrecedence.later(state.precedence, theirs);
        if (precedence != state.precedence) {
          state.precedence = precedence;
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
