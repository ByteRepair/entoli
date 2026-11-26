import "dart:async";
import "dart:convert";

import "package:agent_chat/data/sync/settings_sync.dart";
import "package:entoli_core/model/sync/protocol.dart";
import "package:entoli_core/model/sync/settings_merge.dart";
import "package:flutter_test/flutter_test.dart";

/// One device's settings, as a map.
class _Settings implements SyncedSettings {
  _Settings(this.items);

  SyncedItems items;
  var writes = 0;

  @override
  SyncedItems read() => items;

  @override
  Future<void> write(SyncedItems items) async {
    writes++;
    this.items = {
      for (final MapEntry(:key, :value) in items.entries) key: ?value,
    };
  }
}

class _Ledger implements SettingsLedger {
  final states = <String, String>{};

  @override
  Future<SettingsPairState> read(String peerId) async =>
      SettingsPairState.fromJson(jsonDecode(states[peerId] ?? "null"));

  @override
  Future<void> write(String peerId, SettingsPairState state) async =>
      states[peerId] = jsonEncode(state.toJson());

  @override
  Future<void> forget(String peerId) async => states.remove(peerId);
}

/// [to]'s end of the pair: what is sent goes to [to] as it would over the
/// wire, through JSON.
class _Link implements SettingsPeer {
  _Link(this.deviceId);

  @override
  final String deviceId;
  late SettingsSync to;
  late _Link back;
  final sent = <SyncSettingsOffer>[];

  @override
  Future<void> send(SyncMessage message) async {
    final offer =
        SyncMessage.fromJson(jsonDecode(jsonEncode(message.toJson())))
            as SyncSettingsOffer;
    sent.add(offer);
    scheduleMicrotask(() => to.received(back, offer));
  }
}

void main() {
  late SettingsSync a, b;
  late _Settings onA, onB;
  late _Link toB, toA;

  setUp(() {
    a = SettingsSync(selfId: "A", ledger: _Ledger());
    b = SettingsSync(selfId: "B", ledger: _Ledger());
    onA = _Settings({
      profileItem: {"name": "Ann"},
      "provider:x": {"name": "X", "key": "kx"},
    });
    onB = _Settings({
      profileItem: {"name": "Bob"},
      "provider:y": {"name": "Y", "key": "ky"},
    });
    a.settings = onA;
    b.settings = onB;
    // The link A sends to B over is B, as A knows it.
    toB = _Link("B")..to = b;
    toA = _Link("A")..to = a;
    toB.back = toA;
    toA.back = toB;
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> connect() async {
    await a.greet(toB);
    await b.greet(toA);
    await settle();
  }

  test("nothing is synced until a precedence is chosen", () async {
    await connect();
    expect(a.undecided.value, {"B"});
    expect(b.undecided.value, {"A"});
    expect(onA.writes + onB.writes, 0);
    expect([...toB.sent, ...toA.sent].every((o) => o.items.isEmpty), isTrue);
  });

  test(
    "the chosen device's profile is kept, and providers are joined",
    () async {
      await connect();
      await b.choose("A", "B");
      await settle();
      expect(a.undecided.value, isEmpty);
      expect(b.undecided.value, isEmpty);
      expect(onA.items[profileItem], {"name": "Bob"});
      expect(sameItems(onA.items, onB.items), isTrue);
      expect(onA.items.keys, containsAll(["provider:x", "provider:y"]));
    },
  );

  test("a later edit on either side reaches the other", () async {
    await connect();
    await a.choose("B", "A");
    await settle();
    onB.items = {
      ...onB.items,
      "provider:x": {"name": "X", "key": "new"},
    };
    b.changed();
    await settle();
    expect(onA.items["provider:x"], {"name": "X", "key": "new"});
    expect(sameItems(onA.items, onB.items), isTrue);
  });

  test("a conflict goes to the winner", () async {
    await connect();
    await a.choose("B", "A");
    await settle();
    // Both edit the same field before either hears of the other's.
    onA.items = {
      ...onA.items,
      profileItem: {"name": "Ann A"},
    };
    onB.items = {
      ...onB.items,
      profileItem: {"name": "Ann B"},
    };
    a.changed();
    b.changed();
    await settle();
    expect(onA.items[profileItem], {"name": "Ann A"});
    expect(sameItems(onA.items, onB.items), isTrue);
  });

  test("No Sync keeps each device's own", () async {
    await connect();
    await a.choose("B", null);
    await settle();
    expect(b.undecided.value, isEmpty);
    expect(b.precedences.value["A"]?.syncs, isFalse);
    expect(onA.items[profileItem], {"name": "Ann"});
    expect(onB.items[profileItem], {"name": "Bob"});
    onA.items = {
      profileItem: {"name": "Changed"},
    };
    a.changed();
    await settle();
    expect(onB.items[profileItem], {"name": "Bob"});
  });

  test("the ledger keeps hashes, not keys", () async {
    final ledger = _Ledger();
    a = SettingsSync(selfId: "A", ledger: ledger)..settings = onA;
    toA.to = a;
    await connect();
    await a.choose("B", "A");
    await settle();
    expect(ledger.states["B"], isNot(contains("kx")));
    expect(ledger.states["B"], isNot(contains("ky")));
  });
}
