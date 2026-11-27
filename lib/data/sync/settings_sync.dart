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
  /// is not kept. [replaced] is a provider gone for another of its name, the
  /// removed id to the kept one.
  Future<void> write(
    SyncedItems items, {
    Map<String, String> replaced = const {},
  });
}

/// What one pair has settled about its settings, kept per peer: who wins a
/// conflict, and what the two last agreed.
class SettingsPairState {
  SettingsPairState({this.precedence, this.base});

  SyncPrecedence? precedence;
  MergeBase? base;

  bool get syncs => precedence?.syncs ?? false;

  Map<String, Object?> toJson() => {
    "precedence": ?precedence?.toJson(),
    "base": ?base?.toJson(),
  };

  static SettingsPairState fromJson(Object? json) => json is Map
      ? SettingsPairState(
          precedence: SyncPrecedence.fromJson(json["precedence"]),
          base: MergeBase.fromJson(json["base"]),
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

  var _made = false;

  @override
  Future<void> write(String peerId, SettingsPairState state) async {
    if (!_made) {
      await _fs.directory(directory).create(recursive: true);
      _made = true;
    }
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
/// question. Every offer is answered, if only with the precedence.
///
/// Peers are by id: [greet] and [gone] are the hub's word on which are
/// connected, and its send reaches them.
class SettingsSync {
  SettingsSync({
    required this.selfId,
    required this.ledger,
    required this.send,
    Future<DateTime?> Function(String peerId)? pairedAt,
  }) : _pairedAt = pairedAt ?? ((_) async => null);

  final String selfId;
  final SettingsLedger ledger;

  /// The hub's way to a connected peer.
  final Future<void> Function(String peerId, SyncMessage message) send;

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

  final _live = <String>{};

  /// Each pair's state as the ledger holds it, read once: this is its only
  /// writer.
  final _states = <String, SettingsPairState>{};

  /// What this device's unanswered offer to each peer held, which the reply
  /// is merged against: an edit made since it went is this device's, and
  /// kept. One offer is out per pair at a time, since a second would move
  /// what the first's reply is merged against; edits made meanwhile go with
  /// the offer the reply prompts.
  final _sent = <String, MergeBase>{};

  /// Every message of a pair is handled in turn, so one merge's write is in
  /// before the next reads.
  final _queues = <String, Future<void>>{};

  /// [work] after the pair's earlier work; its failure is the caller's, and
  /// logged. The queue is dropped once it is drained.
  Future<void> _serial(String peerId, Future<void> Function() work) {
    final next = (_queues[peerId] ?? Future.value()).then((_) => work());
    late final Future<void> tail;
    tail = next
        .catchError((Object e) {
          logFailure("sync", "keeping settings in step with $peerId failed", e);
        })
        .whenComplete(() {
          if (identical(_queues[peerId], tail)) _queues.remove(peerId);
        });
    _queues[peerId] = tail;
    return next;
  }

  Future<SettingsPairState> _state(String peerId) async =>
      _states[peerId] ??= await ledger.read(peerId);

  void _show(String peerId) {
    final precedence = _states[peerId]?.precedence;
    if (!precedences.value.containsKey(peerId) ||
        precedences.value[peerId] != precedence) {
      precedences.value = {...precedences.value, peerId: precedence};
    }
    final waiting = {
      for (final id in _live)
        if (_states[id] case final state? when state.precedence == null) id,
    };
    if (!setEquals(waiting, undecided.value)) undecided.value = waiting;
  }

  /// [peerId]'s choice, read for a page that shows it while the pair is not
  /// connected.
  Future<void> recall(String peerId) async {
    if (precedences.value.containsKey(peerId)) return;
    await _serial(peerId, () async {
      await _state(peerId);
      _show(peerId);
    });
  }

  /// [peerId] is up: it is told what this device has, or asked to choose.
  Future<void> greet(String peerId) {
    _live.add(peerId);
    return _serial(peerId, () async {
      await _state(peerId);
      _show(peerId);
      await _offer(peerId);
    });
  }

  void gone(String peerId) {
    _live.remove(peerId);
    _sent.remove(peerId);
    _show(peerId);
  }

  /// The pair's precedence chosen here, now: [winner] is a device's id, or
  /// null for the two not syncing these.
  Future<void> choose(String peerId, String? winner) =>
      _serial(peerId, () async {
        final state = await _state(peerId);
        _decide(
          peerId,
          state,
          SyncPrecedence(winner: winner, decidedAt: DateTime.now().toUtc()),
        );
        await ledger.write(peerId, state);
        _show(peerId);
        if (_live.contains(peerId)) await _offer(peerId);
      });

  /// The pair is unpaired: what it settled goes with it.
  Future<void> forget(String peerId) => _serial(peerId, () async {
    await ledger.forget(peerId);
    _states.remove(peerId);
    precedences.value = {...precedences.value}..remove(peerId);
    gone(peerId);
  });

  /// This device's settings changed: each synced peer that does not hold
  /// them yet, and has no offer out, is offered them.
  void changed() {
    final items = settings?.read();
    if (items == null) return;
    for (final peerId in _live) {
      unawaited(
        _serial(peerId, () async {
          final state = await _state(peerId);
          if (!state.syncs || _sent.containsKey(peerId)) return;
          if (state.base?.agrees(items) ?? false) return;
          await _offer(peerId);
        }),
      );
    }
  }

  /// [precedence] made the pair's, where it is new: a new choice is which
  /// settings to keep, as at a first sync, so what was agreed goes. Whether
  /// it was new.
  bool _decide(String peerId, SettingsPairState state, SyncPrecedence? to) {
    if (to == state.precedence) return false;
    state
      ..precedence = to
      ..base = null;
    _sent.remove(peerId);
    return true;
  }

  /// What this device has, where the pair syncs; its precedence either way.
  Future<void> _offer(String peerId) async {
    final state = _states[peerId]!;
    if (!state.syncs) return _tell(peerId, state, reply: false);
    final items = settings?.read();
    // Nothing to read is not nothing held: an empty offer would take the
    // peer's settings away.
    if (items == null) return;
    _sent[peerId] = MergeBase.of(items);
    await send(
      peerId,
      SyncMessage.settingsOffer(
        items: items,
        precedence: state.precedence?.toJson(),
      ),
    );
  }

  /// This device's precedence and no items.
  Future<void> _tell(
    String peerId,
    SettingsPairState state, {
    required bool reply,
  }) => send(
    peerId,
    SyncMessage.settingsOffer(
      items: const {},
      precedence: state.precedence?.toJson(),
      reply: reply,
    ),
  );

  /// The peer's precedence in [json], unless it predates the pairing.
  Future<SyncPrecedence?> _fresh(String peerId, Object? json) async {
    final theirs = SyncPrecedence.fromJson(json);
    if (theirs == null) return null;
    final paired = await _pairedAt(peerId);
    return paired != null && theirs.decidedAt.isBefore(paired) ? null : theirs;
  }

  /// An offer or a reply from [peerId].
  Future<void> received(String peerId, SyncSettingsOffer offer) =>
      _serial(peerId, () async {
        final state = await _state(peerId);
        final offered = offer.reply ? _sent.remove(peerId) : null;
        final theirs = await _fresh(peerId, offer.precedence);
        if (_decide(
          peerId,
          state,
          SyncPrecedence.later(state.precedence, theirs),
        )) {
          await ledger.write(peerId, state);
        }
        _show(peerId);
        final synced = settings;
        if (!state.syncs || synced == null) {
          if (!offer.reply) await _tell(peerId, state, reply: true);
          return;
        }
        // Made before they knew the pair syncs: this device's offer goes
        // instead, which they answer.
        if (!(theirs?.syncs ?? false)) {
          if (!offer.reply) await _offer(peerId);
          return;
        }
        final remote = {
          for (final MapEntry(:key, :value) in offer.items.entries) key: ?value,
        };
        if (offer.reply) {
          return _replied(peerId, state, synced, remote, offered);
        }
        await _answer(peerId, state, synced, remote);
      });

  /// The peer's offer merged here, and what it made sent back as agreed.
  Future<void> _answer(
    String peerId,
    SettingsPairState state,
    SyncedSettings synced,
    SyncedItems remote,
  ) async {
    final merged = await _merge(state, synced, remote, state.base);
    state.base = MergeBase.of(merged);
    await ledger.write(peerId, state);
    // An offer of this device's still out is answered against this.
    if (_sent.containsKey(peerId)) _sent[peerId] = state.base!;
    await send(
      peerId,
      SyncMessage.settingsOffer(
        items: merged,
        precedence: state.precedence?.toJson(),
        reply: true,
      ),
    );
  }

  /// The peer's answer to this device's offer, [offered]: what it made is
  /// agreed, and an edit made here since the offer went goes out again.
  Future<void> _replied(
    String peerId,
    SettingsPairState state,
    SyncedSettings synced,
    SyncedItems remote,
    MergeBase? offered,
  ) async {
    final merged = await _merge(state, synced, remote, offered ?? state.base);
    state.base = MergeBase.of(remote);
    await ledger.write(peerId, state);
    if (!sameItems(merged, remote)) await _offer(peerId);
  }

  /// [remote] merged with this device's settings against [base], written
  /// where it changes them.
  Future<SyncedItems> _merge(
    SettingsPairState state,
    SyncedSettings synced,
    SyncedItems remote,
    MergeBase? base,
  ) async {
    final local = synced.read();
    final (:items, :replaced) = mergeSettings(
      local: local,
      remote: remote,
      base: base,
      localWins: state.precedence!.winner == selfId,
    );
    if (!sameItems(items, local)) {
      await synced.write(items, replaced: replaced);
    }
    return items;
  }
}
