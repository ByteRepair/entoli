import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/marketplace/marketplace.dart";

MarketplaceLocation location(Map<String, Object?> json) =>
    MarketplaceLocation.fromJson("upstream/x", json);

/// One complete record, as the site's build writes it.
const complete = {
  "repo": "some/source",
  "dir": "skills/x",
  "files": ["SKILL.md", "README.md"],
};

void main() {
  test("a file's address is raw content at the published ref", () {
    final pinned = location({...complete, "ref": "main"});
    expect(
      pinned.file("SKILL.md").toString(),
      "https://raw.githubusercontent.com/some/source/main/skills/x/SKILL.md",
    );
    expect(
      pinned.file("README.md").toString(),
      "https://raw.githubusercontent.com/some/source/main/skills/x/README.md",
    );
  });

  test("an unpinned ref reads the default branch, as raw spells it", () {
    expect(
      location(complete).file("SKILL.md").toString(),
      "https://raw.githubusercontent.com/some/source/HEAD/skills/x/SKILL.md",
    );
  });

  test("a record missing a piece is refused, naming which", () {
    for (final (absent, said) in [
      ("repo", "no repository recorded"),
      ("dir", "no directory recorded"),
      ("files", "no file list recorded"),
    ]) {
      final broken = {...complete}..remove(absent);
      expect(
        () => location(broken),
        throwsA(predicate(
          (e) => e is FormatException && "$e".contains(said),
        )),
      );
    }
  });

  test("a file list is a list of strings", () {
    expect(
      () => location({...complete, "files": [1]}),
      throwsA(predicate(
        (e) => e is FormatException && "$e".contains("no file list recorded"),
      )),
    );
  });

  test("ref is a string or nothing", () {
    expect(
      () => location({...complete, "ref": 3}),
      throwsA(predicate(
        (e) => e is FormatException && "$e".contains("ref is not a string"),
      )),
    );
    // A string is taken as it is.
    expect(location({...complete, "ref": "v1.0.0"}).ref, "v1.0.0");
    // Nothing is null, the default-branch reading.
    expect(location(complete).ref, isNull);
  });
}