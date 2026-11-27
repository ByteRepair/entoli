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
  Future<void> write(
    SyncedItems items, {
    Map<String, String> replaced = const {},
  }) async {
    writes++;
    this.items = items;
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

/// Two devices wired to each other: what one sends goes to the other as it
/// would over the wire, through JSON.
class _Pair {
  late SettingsSync a, b;
  final sent = <String, List<SyncSettingsOffer>>{"A": [], "B": []};

  /// [from]'s send, to the other.
  Future<void> Function(String, SyncMessage) sendOf(String from) =>
      (to, message) async {
        final offer =
            SyncMessage.fromJson(jsonDecode(jsonEncode(message.toJson())))
                as SyncSettingsOffer;
        sent[from]!.add(offer);
        scheduleMicrotask(() => (to == "B" ? b : a).received(from, offer));
      };
}

void main() {
  late _Pair pair;
  late _Settings onA, onB;
  late SettingsSync a, b;

  setUp(() {
    pair = _Pair();
    a = pair.a = SettingsSync(
      selfId: "A",
      ledger: _Ledger(),
      send: pair.sendOf("A"),
    );
    b = pair.b = SettingsSync(
      selfId: "B",
      ledger: _Ledger(),
      send: pair.sendOf("B"),
    );
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
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> connect() async {
    await a.greet("B");
    await b.greet("A");
    await settle();
  }

  test("nothing is synced until a precedence is chosen", () async {
    await connect();
    expect(a.undecided.value, {"B"});
    expect(b.undecided.value, {"A"});
    expect(onA.writes + onB.writes, 0);
    expect(
      [...pair.sent["A"]!, ...pair.sent["B"]!].every((o) => o.items.isEmpty),
      isTrue,
    );
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
    a = pair.a = SettingsSync(
      selfId: "A",
      ledger: ledger,
      send: pair.sendOf("A"),
    )..settings = onA;
    await connect();
    await a.choose("B", "A");
    await settle();
    expect(ledger.states["B"], isNot(contains("kx")));
    expect(ledger.states["B"], isNot(contains("ky")));
  });

  test("a second edit made before the first's reply is kept", () async {
    await connect();
    await a.choose("B", "A");
    await settle();
    onA.items = {
      ...onA.items,
      profileItem: {"name": "first"},
    };
    a.changed();
    // Before the reply to the first offer has come back.
    onA.items = {
      ...onA.items,
      profileItem: {"name": "second"},
    };
    a.changed();
    await settle();
    expect(onA.items[profileItem], {"name": "second"});
    expect(onB.items[profileItem], {"name": "second"});
  });

  test("a choice the peer kept from before the pairing is not taken", () async {
    final paired = DateTime.now().toUtc();
    a = pair.a = SettingsSync(
      selfId: "A",
      ledger: _Ledger(),
      send: pair.sendOf("A"),
      pairedAt: (_) async => paired,
    )..settings = onA;
    // B's choice, from the pairing A has since forgotten.
    final stale = SyncPrecedence(
      winner: "B",
      decidedAt: paired.subtract(const Duration(days: 1)),
    );
    await a.greet("B");
    await pair.sendOf("B")(
      "A",
      SyncMessage.settingsOffer(items: onB.items, precedence: stale.toJson()),
    );
    await settle();
    expect(a.undecided.value, {"B"});
    expect(onA.items[profileItem], {"name": "Ann"});
    // Answered, if only with its own precedence: B's offer is not left
    // waiting, which would hold B's edits back for the connection.
    expect(pair.sent["A"]!.last.reply, isTrue);
  });
}
