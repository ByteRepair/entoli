import "package:entoli_core/model/sync/settings_merge.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  MergedSettings mergeBoth(
    SyncedItems local,
    SyncedItems remote, {
    SyncedItems? agreed,
    bool localWins = true,
  }) {
    final base = agreed == null ? null : MergeBase.of(agreed);
    final here = mergeSettings(
      local: local,
      remote: remote,
      base: base,
      localWins: localWins,
    );
    // The other device, merging the same two from its side, reaches the
    // same items.
    final there = mergeSettings(
      local: remote,
      remote: local,
      base: base,
      localWins: !localWins,
    );
    expect(
      sameItems(here.items, there.items),
      isTrue,
      reason: "$here vs $there",
    );
    expect(here.replaced, there.replaced);
    return here;
  }

  SyncedItems merge(
    SyncedItems local,
    SyncedItems remote, {
    SyncedItems? agreed,
    bool localWins = true,
  }) => mergeBoth(local, remote, agreed: agreed, localWins: localWins).items;

  group("names stay unique", () {
    // Each device added Ollama Cloud for itself, under an id of its own.
    final here = {
      "provider:mine": {"name": "Ollama Cloud", "key": "k-here"},
      "provider:a": {"name": "A"},
    };
    final there = {
      "provider:theirs": {"name": "ollama cloud ", "key": "k-there"},
      "provider:b": {"name": "B"},
    };

    test("the winner's of two sharing a name stays", () {
      expect(merge(here, there), {
        "provider:mine": {"name": "Ollama Cloud", "key": "k-here"},
        "provider:a": {"name": "A"},
        "provider:b": {"name": "B"},
      });
      expect(merge(here, there, localWins: false).keys, {
        "provider:theirs",
        "provider:a",
        "provider:b",
      });
    });

    test("a rename is the same provider, synced by its id", () {
      final agreed = {
        "provider:x": {"name": "Work"},
      };
      expect(
        merge(
          {
            "provider:x": {"name": "Work"},
          },
          {
            "provider:x": {"name": "University"},
          },
          agreed: agreed,
        ),
        {
          "provider:x": {"name": "University"},
        },
      );
    });

    test("of two renamed onto one name, the winner's own stays", () {
      final agreed = {
        "provider:x": {"name": "Home"},
        "provider:y": {"name": "Work"},
      };
      // The winner renamed y to Lab; the loser renamed x to Lab.
      final winner = {
        "provider:x": {"name": "Home"},
        "provider:y": {"name": "Lab"},
      };
      final loser = {
        "provider:x": {"name": "Lab"},
        "provider:y": {"name": "Work"},
      };
      final merged = mergeBoth(winner, loser, agreed: agreed);
      expect(merged.items, {
        "provider:y": {"name": "Lab"},
      });
      expect(merged.replaced, {"x": "y"});
    });
  });

  group("a first sync", () {
    test("keeps an item only one side has", () {
      expect(
        merge(
          {
            "provider:a": {"name": "A"},
          },
          {
            "provider:b": {"name": "B"},
          },
        ),
        {
          "provider:a": {"name": "A"},
          "provider:b": {"name": "B"},
        },
      );
    });

    test("takes an item both have whole from the winner", () {
      final local = {
        profileItem: {"name": "Ann", "profession": "nurse"},
      };
      final remote = {
        profileItem: {"name": "Bob", "religion": "none"},
      };
      expect(merge(local, remote)[profileItem], local[profileItem]);
      expect(
        merge(local, remote, localWins: false)[profileItem],
        remote[profileItem],
      );
    });
  });

  group("after agreeing", () {
    final agreed = {
      profileItem: {"name": "Ann", "profession": "nurse"},
      "provider:a": {"name": "A", "key": "k1"},
    };

    test("keeps the one side's edit of a field", () {
      final merged = merge(
        {
          profileItem: {"name": "Ann", "profession": "doctor"},
          "provider:a": {"name": "A", "key": "k1"},
        },
        agreed,
        agreed: agreed,
        localWins: false,
      );
      expect(merged[profileItem], {"name": "Ann", "profession": "doctor"});
    });

    test("merges edits of different fields", () {
      final merged = merge(
        {
          profileItem: {"name": "Ann", "profession": "doctor"},
          "provider:a": {"name": "A", "key": "k1"},
        },
        {
          profileItem: {"name": "Anna", "profession": "nurse"},
          "provider:a": {"name": "A", "key": "k2"},
        },
        agreed: agreed,
      );
      expect(merged[profileItem], {"name": "Anna", "profession": "doctor"});
      expect(merged["provider:a"], {"name": "A", "key": "k2"});
    });

    test("gives a field both changed to the winner", () {
      final local = {
        ...agreed,
        profileItem: {"name": "Ann", "profession": "doctor"},
      };
      final remote = {
        ...agreed,
        profileItem: {"name": "Ann", "profession": "pilot"},
      };
      expect(
        merge(local, remote, agreed: agreed)[profileItem]!["profession"],
        "doctor",
      );
      expect(
        merge(
          local,
          remote,
          agreed: agreed,
          localWins: false,
        )[profileItem]!["profession"],
        "pilot",
      );
    });

    test("drops a field one side cleared", () {
      final merged = merge(
        {
          ...agreed,
          profileItem: {"name": "Ann"},
        },
        agreed,
        agreed: agreed,
      );
      expect(merged[profileItem], {"name": "Ann"});
    });

    test("drops an item one side removed and the other left alone", () {
      final merged = merge(
        {profileItem: agreed[profileItem]!},
        agreed,
        agreed: agreed,
        localWins: false,
      );
      expect(merged["provider:a"], isNull);
    });

    test("an item removed against an edit is the winner's", () {
      final edited = {
        ...agreed,
        "provider:a": {"name": "A", "key": "k2"},
      };
      final removed = {profileItem: agreed[profileItem]!};
      expect(
        merge(edited, removed, agreed: agreed)["provider:a"],
        edited["provider:a"],
      );
      expect(
        merge(edited, removed, agreed: agreed, localWins: false)["provider:a"],
        isNull,
      );
    });

    test("keeps an item added since on one side", () {
      final merged = merge(
        {
          ...agreed,
          "provider:b": {"name": "B"},
        },
        agreed,
        agreed: agreed,
        localWins: false,
      );
      expect(merged["provider:b"], {"name": "B"});
    });
  });

  test("a base holds hashes, not the values", () {
    final base = MergeBase.of({
      "provider:a": {"key": "sk-secret"},
    });
    expect("${base.toJson()}", isNot(contains("sk-secret")));
    expect(MergeBase.fromJson(base.toJson())!.items, base.items);
  });

  test("the later precedence wins, the same on both sides", () {
    final early = SyncPrecedence(winner: "a", decidedAt: DateTime.utc(2026));
    final late = SyncPrecedence(winner: null, decidedAt: DateTime.utc(2027));
    expect(SyncPrecedence.later(early, late), late);
    expect(SyncPrecedence.later(late, early), late);
    expect(SyncPrecedence.later(null, early), early);
    final tie = SyncPrecedence(winner: "b", decidedAt: DateTime.utc(2026));
    expect(SyncPrecedence.later(early, tie), SyncPrecedence.later(tie, early));
    expect(SyncPrecedence.fromJson(late.toJson()), late);
  });
}
