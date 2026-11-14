import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/marketplace/marketplace.dart";
import "package:agent_chat/app/marketplace/groups.dart";

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
  test("the entries a record lists make its collection", () {
    final (front, collections) = groupIntoCollections(
      [
        localEntry("alpha"),
        remoteEntry("zoo/gcs"),
        localEntry("build"),
        remoteEntry("zoo/bigquery"),
        // A key no record lists stays on the front page, whatever its shape.
        remoteEntry("zoo/loose"),
        remoteEntry("solo"),
      ],
      {
        "zoo": (
          name: "Google",
          summary: "Cloud.",
          members: ["zoo/bigquery", "zoo/gcs"],
        ),
        "acme": (name: "Acme", summary: "", members: ["build"]),
      },
    );
    expect(front.map((e) => e.slug), ["alpha", "zoo/loose", "solo"]);
    // By name, not slug; members in the order they came in.
    expect(collections.map((c) => c.name), ["Acme", "Google"]);
    expect(collections.last.members.map((e) => e.slug), [
      "zoo/gcs",
      "zoo/bigquery",
    ]);
    expect(collections.last.summary, "Cloud.");
  });

  test("a record whose members the index lacks is no collection", () {
    final (front, collections) = groupIntoCollections(
      [localEntry("alpha")],
      {
        "zoo": (name: "Google", summary: "", members: ["gone"]),
      },
    );
    expect(front.length, 1);
    expect(collections, isEmpty);
  });

  test("a collection is external when every member is", () {
    final (_, collections) = groupIntoCollections(
      [remoteEntry("a"), remoteEntry("b"), localEntry("c")],
      {
        "far": (name: "Far", summary: "", members: ["a", "b"]),
        "mixed": (name: "Mixed", summary: "", members: ["b", "c"]),
      },
    );
    expect(collections.map((c) => (c.name, c.external)), [
      ("Far", true),
      ("Mixed", false),
    ]);
  });

  test("a byline names the first author and how many more", () {
    MarketplaceEntry by(String author) =>
        MarketplaceEntry(slug: "x", name: "x", description: "", author: author);
    expect(by("").byline, isNull);
    expect(by("Entoli").byline, "by Entoli");
    expect(by("ana, bo , cy").byline, "by ana and 2 more");
    expect(by("ana, bo , cy").authors, ["ana", "bo", "cy"]);
  });

  test("collections match on name or summary", () {
    final (_, collections) = groupIntoCollections(
      [remoteEntry("g/a"), remoteEntry("m/a")],
      {
        "g": (name: "Google", summary: "Cloud and BigQuery.", members: ["g/a"]),
        "m": (name: "Microsoft", summary: "Azure.", members: ["m/a"]),
      },
    );
    expect(collectionsMatching(collections, " GOOG").map((c) => c.name), [
      "Google",
    ]);
    expect(collectionsMatching(collections, "azure").map((c) => c.name), [
      "Microsoft",
    ]);
    expect(collectionsMatching(collections, "").length, 2);
    expect(collectionsMatching(collections, "wordpress"), isEmpty);
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
      localEntry("alpha", tags: ["zulu", "beta", "all"]),
      localEntry("beta", tags: ["zulu", "all"]),
      remoteEntry("gamma", tags: ["beta", "all"]),
    ]);
    // "all" is on every entry, so it narrows nothing and is not offered.
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
