import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/marketplace/marketplace.dart";
import "package:agent_chat/ui/marketplace/marketplace_groups.dart";

/// A site's-own entry, under [name] with [tags], as the section index names
/// one — no location, which is what the grouping reads.
MarketplaceEntry localEntry(String name, {List<String> tags = const []}) =>
    MarketplaceEntry(
      slug: name,
      name: name,
      description: "About $name.",
      author: "Entoli Team",
      tags: tags,
    );

/// A remote entry: its location is the whole difference from [localEntry].
MarketplaceEntry remoteEntry(String name, {List<String> tags = const []}) =>
    MarketplaceEntry(
      slug: name,
      name: name,
      description: "About $name.",
      author: "The Upstream Authors",
      tags: tags,
      location: MarketplaceLocation(
        repo: "some/source",
        ref: null,
        dir: "skills/$name",
        files: const ["SKILL.md"],
      ),
    );

void main() {
  test("the list groups the site's own entries ahead of the remote ones", () {
    final groups = groupByOrigin([
      localEntry("alpha"),
      remoteEntry("alpha"),
      localEntry("beta"),
      remoteEntry("beta"),
    ]);
    expect(groups.local.map((e) => e.name), ["alpha", "beta"]);
    expect(groups.remote.map((e) => e.name), ["alpha", "beta"]);

    // A category of one either side: the other list is just empty, rather
    // than the row moving where it does not belong.
    expect(groupByOrigin([remoteEntry("alpha")]).local, isEmpty);
    expect(groupByOrigin([remoteEntry("alpha")]).remote.map((e) => e.name), [
      "alpha",
    ]);
    expect(groupByOrigin([localEntry("alpha")]).remote, isEmpty);
  });

  test("searching matches the name and the description alike", () {
    final entries = [localEntry("alpha"), localEntry("beta")];
    // The name.
    expect(entriesMatching(entries, "alp", {}).map((e) => e.name), ["alpha"]);
    // The description.
    expect(entriesMatching(entries, "about beta", {}).map((e) => e.name), [
      "beta",
    ]);
    // Case and surrounding space are the needle's, not the match's.
    expect(entriesMatching(entries, "  ALP ", {}).map((e) => e.name), [
      "alpha",
    ]);
    // Neither.
    expect(entriesMatching(entries, "gamma", {}), isEmpty);
    // An empty query is no search: everything stands.
    expect(
      entriesMatching(
        [localEntry("alpha"), remoteEntry("beta")],
        "  ",
        {},
      ).length,
      2,
    );
  });

  test("a matching list keeps the order it came in", () {
    final entries = [localEntry("zeta"), localEntry("alpha")];
    // Both match on "a", and the came-in order — not the alphabetical one —
    // is what stands: the filter ranks nothing, it only removes.
    expect(entriesMatching(entries, "a", {}).map((e) => e.name), [
      "zeta",
      "alpha",
    ]);
  });

  test("the tag ticks are the intersection of what the entry carries", () {
    final entries = [
      localEntry("alpha", tags: ["x"]),
      localEntry("beta", tags: ["x", "y"]),
      localEntry("gamma"),
    ];
    // One tag: both carriers pass, tags and no-tags do not.
    expect(entriesMatching(entries, "", {"x"}).map((e) => e.name), [
      "alpha",
      "beta",
    ]);
    // Two: the entry carrying both is the only one left.
    expect(entriesMatching(entries, "", {"x", "y"}).map((e) => e.name), [
      "beta",
    ]);
    // No ticks: the whole list.
    expect(entriesMatching(entries, "", const <String>{}).length, 3);
  });

  test("search and ticks hold together", () {
    final entries = [
      localEntry("alpha", tags: ["x"]),
      localEntry("beta", tags: ["x"]),
      localEntry("gamma", tags: ["x"]),
    ];
    expect(entriesMatching(entries, "beta", {"x"}).map((e) => e.name), [
      "beta",
    ]);
    expect(entriesMatching(entries, "beta", {"y"}), isEmpty);
  });

  test("tags list every tag once, with its count, alphabetically", () {
    final tags = tagsOf([
      localEntry("alpha", tags: ["zulu", "beta"]),
      localEntry("beta", tags: ["zulu"]),
      remoteEntry("gamma", tags: ["beta"]),
    ]);
    expect(tags, [("beta", 2), ("zulu", 2)]);

    // The sort is by what a tag reads as, not what it holds: ASCII order
    // would put "Zulu" ahead of "alpha" (Z is 90, a is 97), and a plain
    // compareTo fails this expectation.
    expect(
      tagsOf([
        localEntry("alpha", tags: ["Zulu"]),
        localEntry("beta", tags: ["alpha"]),
      ]),
      [("alpha", 1), ("Zulu", 1)],
    );
  });
}
