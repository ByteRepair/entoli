import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/marketplace/marketplace.dart";
import "package:agent_chat/ui/marketplace/marketplace_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../data/fake_network.dart";
import "../fakes.dart" show onePixelPng;
import "../harness.dart";

/// A skill package the intake accepts, built in memory — the same shape the
/// site's `<slug>.skill` is.
const _letterboxMd =
    "---\nname: letterbox\ndescription: frames the reply\n---\n\nFrame it.\n";

Uint8List letterboxPackage() => packageSkillBytes(SkillPackage("letterbox", [
      ("SKILL.md", Uint8List.fromList(utf8.encode(_letterboxMd))),
      ("references/tone.md", Uint8List.fromList(utf8.encode("calm\n"))),
    ]));

/// An agent's PROMPT.md, frontmatter and body, as the site serves it.
const _diaryPrompt = """---
description: Keeps a diary of what was done.
---

You keep a project diary. Append what was done each turn.
""";

/// An agent's PROMPT.md from the remote fixtures' source repository.
const _upstreamPrompt = """---
description: Writes letters home.
---

You write a letter home each turn.
""";

/// The remote fixtures' source repository, as the ext index names it, and
/// the directory each of its entries carries.
const upstreamRepo = "entoli-test/upstream";
const upstreamSkillDir = "skills/red-letter";
const upstreamAgentDir = "agents/letter-writer";

void main() {
  TestApp? app;
  late FakeNetwork network;

  setUp(() => network = FakeNetwork({}, missingAs404: true));
  tearDown(() {
    network.close();
    app?.dispose();
  });

  /// The path a request to the site carries — under the site's directory on
  /// its host, which is what `request.url.path` is.
  String entryPath(CompletionKind kind, String slug, String file) =>
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/$slug/$file").path;

  /// The skill package's path: beside the entry's directories, at the
  /// section root.
  String packagePath(CompletionKind kind, String slug) =>
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/$slug.skill").path;

  /// The `index.json` path for a section.
  String indexPath(CompletionKind kind) =>
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/index.json").path;

  /// The ext index's path for a section — the site's other index, where each
  /// remote entry's source location is recorded.
  String extIndexPath(CompletionKind kind) =>
      Uri.parse("$marketplaceBaseUrl/ext/${kind.folder}/index.json").path;

  /// The path of one raw file of the remote fixtures' source repository, at
  /// the ref their location records name.
  String rawPath(String dir, String file) =>
      Uri.parse("https://raw.githubusercontent.com/$upstreamRepo/main/$dir/$file")
          .path;

  /// An index naming one skill and one agent, and the files both answer.
  /// [skillPackageBody] stands in for the `.skill` bytes where a test wants
  /// a malformed one; [agentPicture] is whether the agent carries a
  /// `profile.png`. A remote skill and agent ride along: their section rows,
  /// their ext records (where the file lists name all they carry), and the
  /// raw bodies their sources answer with.
  Map<String, List<List<int>>> site({
    String? skillPackageBody,
    bool agentPicture = true,
  }) => {
        indexPath(CompletionKind.skill): [utf8.encode("""{
  "letterbox": {
    "name": "letterbox",
    "description": "Frames the reply.",
    "author": "Entoli Team",
    "version": "1.0.0",
    "tags": ["layout"]
  },
  "upstream/red-letter": {
    "name": "red-letter",
    "description": "Frames the reply from an upstream repository.",
    "author": "The Upstream Authors",
    "version": "2.0.0",
    "tags": ["external"]
  }
}""")],
        indexPath(CompletionKind.agent): [utf8.encode("""{
  "diary": {
    "name": "diary",
    "description": "Keeps a diary of what was done.",
    "author": "Entoli Team"
  },
  "upstream/letter-writer": {
    "name": "letter-writer",
    "description": "Writes letters home.",
    "author": "The Upstream Authors",
    "tags": ["external"]
  }
}""")],
        extIndexPath(CompletionKind.skill): [utf8.encode("""{
  "upstream/red-letter": {
    "repo": "$upstreamRepo",
    "dir": "$upstreamSkillDir",
    "files": ["README.md", "SKILL.md", "references/tone.md"],
    "ref": "main"
  }
}""")],
        extIndexPath(CompletionKind.agent): [utf8.encode("""{
  "upstream/letter-writer": {
    "repo": "$upstreamRepo",
    "dir": "$upstreamAgentDir",
    "files": ["PROMPT.md", "README.md", "profile.png"],
    "ref": "main"
  }
}""")],
        rawPath(upstreamSkillDir, "README.md"): [
          utf8.encode("# Red letter\n\nFrom upstream.\n")
        ],
        rawPath(upstreamSkillDir, "SKILL.md"): [utf8.encode("""---
name: red-letter
description: Frames the reply from upstream.
metadata:
  author: The Upstream Authors
---

Frame it, from upstream.
""")],
        rawPath(upstreamSkillDir, "references/tone.md"): [
          utf8.encode("calm\n")
        ],
        rawPath(upstreamAgentDir, "PROMPT.md"): [utf8.encode(_upstreamPrompt)],
        rawPath(upstreamAgentDir, "README.md"): [
          utf8.encode("# Letter writer\n\nWrites letters.\n")
        ],
        rawPath(upstreamAgentDir, "profile.png"): [onePixelPng],
        entryPath(CompletionKind.skill, "letterbox", "README.md"): [
          utf8.encode("# Letterbox\n\nFrames the reply.\n")
        ],
        // The `.skill` the build serves — beside the entry's directories, at
        // the section root. The fixture's real package, or a body a test
        // asks to stand in for a malformed one.
        packagePath(CompletionKind.skill, "letterbox"): [
          skillPackageBody != null
              ? utf8.encode(skillPackageBody)
              : letterboxPackage(),
        ],
        entryPath(CompletionKind.agent, "diary", "README.md"): [
          utf8.encode("# Diary\n\nKeeps a diary.\n")
        ],
        entryPath(CompletionKind.agent, "diary", "PROMPT.md"): [
          utf8.encode(_diaryPrompt)
        ],
        if (agentPicture)
          entryPath(CompletionKind.agent, "diary", "profile.png"): [onePixelPng],
      };

  /// Pumps the marketplace over the faked site, giving the fetches the real
  /// time they wait on. The pump itself is run inside `runAsync` because the
  /// fetch starts on the first frame, and a fetch mid-flight is the one thing
  /// `settleIo`, after it, cannot advance — and a second `runAsync` from
  /// outside is denied while it waits.
  Future<void> pumpMarket(
    WidgetTester tester,
    Widget child, {
    Map<String, List<List<int>>> bodies = const {},
  }) async {
    network.bodies.addAll(bodies);
    app = TestApp.create(marketplaceClient: network);
    await tester.runAsync(() => app!.pump(tester, child, settle: false));
  }

  /// The marketplace list, seeded and settled, on the opening tab.
  Future<void> pumpList(
    WidgetTester tester, {
    String? skillPackageBody,
    bool agentPicture = true,
  }) =>
      pumpMarket(tester, const MarketplacePage(),
          bodies: site(
            skillPackageBody: skillPackageBody,
            agentPicture: agentPicture,
          ));

  /// Opens an entry's preview and settles it — the list's settle, the tab
  /// flip where there is one, the tap, then a wait for [until], defaulting
  /// to the Install button the loaded preview draws (a refusal draws its
  /// reason where the button would be, and passes its own [until]). The
  /// agent tests sit on the second tab, the skill ones on the opening tab.
  Future<void> openEntry(
    WidgetTester tester, {
    required CompletionKind kind,
    required String slug,
    Finder? until,
  }) async {
    await settleIo(tester);
    if (kind != CompletionKind.skill) {
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
    }
    await tester.tap(find.text(slug));
    await pumpUntil(
        tester,
        until ??
            find.text(kind == CompletionKind.skill
                ? "Install skill"
                : "Install agent"));
    await settleIo(tester);
  }

  testWidgets("tabs list the marketplace's skills and agents", (tester) async {
    await pumpList(tester);
    await settleIo(tester);

    expect(find.text("Skills"), findsWidgets);
    expect(find.text("Agents"), findsOneWidget);
    // Skills first, being the opening tab.
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("Frames the reply."), findsOneWidget);
    expect(find.text("Entoli Team · v1.0.0 · layout"), findsOneWidget);
    // The remote rows joined from the ext index sit in the same list, under
    // the heading, the site's own entries ahead of them.
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("External"), findsOneWidget);
    expect(
      tester.getTopLeft(find.text("letterbox")).dy <
          tester.getTopLeft(find.text("red-letter")).dy,
      isTrue,
    );
    expect(find.text("diary"), findsNothing);

    await tester.tap(find.text("Agents"));
    await settleIo(tester);
    expect(find.text("diary"), findsOneWidget);
    expect(find.text("Keeps a diary of what was done."), findsOneWidget);
    expect(find.text("letter-writer"), findsOneWidget);
    // The agents list has its own halves the same way: diary first, the
    // remote one under the heading.
    expect(find.text("External"), findsOneWidget);
    expect(
      tester.getTopLeft(find.text("diary")).dy <
          tester.getTopLeft(find.text("letter-writer")).dy,
      isTrue,
    );
    expect(find.text("letterbox"), findsNothing);
  });

  testWidgets("the toolbar's search filters the tab on screen", (tester) async {
    await pumpList(tester);
    await settleIo(tester);

    // A name match.
    await tester.enterText(find.byType(TextField), "letter");
    await settleIo(tester);
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("red-letter"), findsOneWidget);

    // A description-only match: the name carries none of it.
    await tester.enterText(find.byType(TextField), "an upstream");
    await settleIo(tester);
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("letterbox"), findsNothing);

    await tester.enterText(find.byType(TextField), "zzz");
    await settleIo(tester);
    expect(find.text("Nothing matches here."), findsOneWidget);

    await tester.tap(find.byTooltip("Clear search"));
    await settleIo(tester);
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("External"), findsOneWidget);
  });

  testWidgets("the tag picker ticks and the list filters", (tester) async {
    await pumpList(tester);
    await settleIo(tester);

    await tester.tap(find.byTooltip("Filter by tag"));
    await settleIo(tester);

    // The tab's tags, each with its entry count.
    expect(find.text("external"), findsOneWidget);
    expect(find.text("layout"), findsOneWidget);
    expect(find.text("1"), findsNWidgets(2));

    await tester.tap(find.text("external"));
    await settleIo(tester);
    expect(find.text("Clear"), findsOneWidget);

    await tester.pageBack();
    await settleIo(tester);

    // The one remote entry carries it; the local half is gone and the
    // heading with it.
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("letterbox"), findsNothing);
    expect(find.text("External"), findsNothing);

    // Reopened, the tick stood; ticking the other tag intersects to nothing.
    await tester.tap(find.byTooltip("Filter by tag"));
    await settleIo(tester);
    await tester.tap(find.text("layout"));
    await settleIo(tester);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.text("Nothing matches here."), findsOneWidget);

    // Clearing gives the whole list back, heading and all.
    await tester.tap(find.byTooltip("Filter by tag"));
    await settleIo(tester);
    await tester.tap(find.text("Clear"));
    await settleIo(tester);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.text("External"), findsOneWidget);
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("red-letter"), findsOneWidget);
  });

  testWidgets("an unreachable marketplace says so and retries", (tester) async {
    await pumpMarket(tester, const MarketplacePage());
    await settleIo(tester);

    expect(find.text("Could not reach the marketplace."), findsOneWidget);
    // The detail is the status, not a JSON parse of an error page.
    expect(find.textContaining("HTTP 404"), findsOneWidget);

    // The retry re-fetches, now answered: an empty index is a working page
    // with nothing in it yet. The fetch is real time again, so the settle
    // gives it more rounds than the default floor — a loaded suite runs
    // these slower than one round covers.
    network.bodies[indexPath(CompletionKind.skill)] = [utf8.encode("{}")];
    await tester.tap(find.text("Try again"));
    await settleIo(tester, least: 20, tries: 80);
    expect(find.text("The marketplace has nothing here yet."), findsOneWidget);
  });

  testWidgets("the sidebar opens it from the tile below Profile",
      (tester) async {
    await pumpMarket(
      tester,
      Scaffold(
        drawer: const Drawer(child: Sidebar()),
        body: const SizedBox.shrink(),
        appBar: AppBar(
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ),
      ),
      bodies: {
        indexPath(CompletionKind.skill): [utf8.encode("{}")],
        indexPath(CompletionKind.agent): [utf8.encode("{}")],
      },
    );
    await settleIo(tester);
    await tester.tap(find.byIcon(Icons.menu));
    await settleIo(tester);
    // The marketplace tile sits between Profile and Settings in the bottom
    // block, which is what "below Profile" is.
    final tiles = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(Sidebar),
          matching:
              find.textContaining(RegExp("^(Profile|Marketplace|Settings)\$")),
        ))
        .map((t) => t.data)
        .toList();
    expect(tiles.indexOf("Profile") < tiles.indexOf("Marketplace"), isTrue);
    expect(tiles.indexOf("Marketplace") < tiles.indexOf("Settings"), isTrue);
    await tester.tap(find.widgetWithText(ListTile, "Marketplace"));
    await settleIo(tester);
    // Over the marketplace page now, with its own tabs.
    expect(find.text("Skills"), findsWidgets);
  });

  testWidgets("a skill's preview renders the README and installs the whole directory",
      (tester) async {
    await pumpList(tester);
    await settleIo(tester);
    // The list row's own meta line, before the push — both renderings assert.
    expect(find.text("Entoli Team · v1.0.0 · layout"), findsOneWidget);
    await openEntry(tester, kind: CompletionKind.skill, slug: "letterbox");

    // The README, drawn as the entry's long description — the meta line the
    // list row drew before the push is the one the preview renders now; the
    // list itself sits behind the opaque route, skipped by the finders.
    expect(find.text("Letterbox"), findsOneWidget);
    expect(find.text("Entoli Team · v1.0.0 · layout"), findsOneWidget);
    // The files the package carries beside SKILL.md.
    expect(find.text("references/tone.md"), findsOneWidget);

    await tester.tap(find.text("Install skill"));
    await settleIo(tester, least: 20, tries: 80);

    final dir = p.join(app!.config.promptsDir(CompletionKind.skill), "letterbox");
    expect(File(p.join(dir, "SKILL.md")).existsSync(), isTrue);
    expect(File(p.join(dir, "references", "tone.md")).existsSync(), isTrue);
    expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), _letterboxMd);

    // Back to the list once it has installed.
    expect(find.text("Install skill"), findsNothing);
    expect(find.text("letterbox"), findsOneWidget);
  });

  // Seeded before any install runs: on Linux the install path leaves the
  // skills directory read-only, so the file the replace drops has to be
  // written before the app lays the directory down.
  testWidgets("installing over an existing skill asks first, and Replace replaces",
      (tester) async {
    await pumpList(tester);
    await settleIo(tester);

    // Seeded after the page pumps: on Linux an install lands its directory
    // read-only again, so the file the replace drops must predate any install.
    final dir = p.join(app!.config.promptsDir(CompletionKind.skill), "letterbox");
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, "SKILL.md")).writeAsStringSync("old\n");
    File(p.join(dir, "obsolete.sh")).writeAsStringSync("old\n");

    await openEntry(tester, kind: CompletionKind.skill, slug: "letterbox");

    await tester.tap(find.text("Install skill"));
    await pumpUntil(tester, find.text("Replace"));
    await tester.tap(find.text("Replace"));
    await settleIo(tester, least: 20, tries: 80);

    // The replace was wholesale: the dropped file is gone, the rest rewritten.
    expect(File(p.join(dir, "obsolete.sh")).existsSync(), isFalse);
    expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), _letterboxMd);
    expect(File(p.join(dir, "references", "tone.md")).existsSync(), isTrue);
  });

    testWidgets("an agent with no picture installs the prompt alone",
        (tester) async {
      await pumpList(tester, agentPicture: false);
      await openEntry(tester, kind: CompletionKind.agent, slug: "diary");

      expect(find.byType(Image), findsNothing);

      await tester.tap(find.text("Install agent"));
      await settleIo(tester, least: 20, tries: 80);

      final agentsDir = app!.config.promptsDir(CompletionKind.agent);
      expect(File(p.join(agentsDir, "diary.md")).readAsStringSync(), _diaryPrompt);
      // No picture served, none written.
      expect(File(p.join(agentsDir, "diary.png")).existsSync(), isFalse);
    });

  testWidgets("an agent's preview shows the picture and installs prompt and picture",
      (tester) async {
    await pumpList(tester);
    await openEntry(tester, kind: CompletionKind.agent, slug: "diary");

    expect(find.text("Diary"), findsOneWidget);
    expect(find.text("Keeps a diary of what was done."), findsOneWidget);
    // The picture served beside the prompt is the preview's face.
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.text("Install agent"));
    await settleIo(tester, least: 20, tries: 80);

    final agentsDir = app!.config.promptsDir(CompletionKind.agent);
    expect(File(p.join(agentsDir, "diary.md")).readAsStringSync(), _diaryPrompt);
    expect(File(p.join(agentsDir, "diary.png")).existsSync(), isTrue);
  });

  testWidgets("a remote skill previews out of its source and installs whole",
      (tester) async {
    await pumpList(tester);
    await settleIo(tester);
    // Its row is the ext record's join; the name the row shows is the entry's.
    await openEntry(tester, kind: CompletionKind.skill, slug: "red-letter");

    // The README from the source repository, drawn the way a local one is,
    // and the file list the ext record named.
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("From upstream."), findsOneWidget);
    expect(find.text("references/tone.md"), findsOneWidget);

    await tester.tap(find.text("Install skill"));
    await settleIo(tester, least: 20, tries: 80);

    // The whole of the listed directory lands under the frontmatter's name.
    final dir = p.join(app!.config.promptsDir(CompletionKind.skill), "red-letter");
    expect(File(p.join(dir, "SKILL.md")).existsSync(), isTrue);
    expect(File(p.join(dir, "README.md")).existsSync(), isTrue);
    expect(File(p.join(dir, "references", "tone.md")).existsSync(), isTrue);
    expect(find.text("Install skill"), findsNothing);
  });

  testWidgets("a remote agent installs prompt and picture", (tester) async {
    await pumpList(tester);
    await openEntry(tester, kind: CompletionKind.agent, slug: "letter-writer");

    expect(find.text("letter-writer"), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.text("Install agent"));
    await settleIo(tester, least: 20, tries: 80);

    // The file name is the remote directory's — the ext key's last segment.
    final agentsDir = app!.config.promptsDir(CompletionKind.agent);
    expect(File(p.join(agentsDir, "letter-writer.md")).readAsStringSync(),
        _upstreamPrompt);
    expect(File(p.join(agentsDir, "letter-writer.png")).existsSync(), isTrue);
  });

  testWidgets("a listing gone stale against its source refuses at the button",
      (tester) async {
    // A file the ext record names, the repository does not answer with.
    final bodies = site()
      ..remove(rawPath(upstreamSkillDir, "references/tone.md"));
    await pumpMarket(tester, const MarketplacePage(), bodies: bodies);
    await openEntry(
      tester,
      kind: CompletionKind.skill,
      slug: "red-letter",
      until: find.textContaining("stale against the source"),
    );

    expect(find.text("Install skill"), findsNothing);
    expect(find.textContaining("stale against the source"), findsOneWidget);
    final dir = p.join(app!.config.promptsDir(CompletionKind.skill), "red-letter");
    expect(Directory(dir).existsSync(), isFalse);
  });

  testWidgets("a malformed ext index is an unreachable marketplace",
      (tester) async {
    await pumpMarket(
      tester,
      const MarketplacePage(),
      bodies: {
        indexPath(CompletionKind.skill): [utf8.encode("{}")],
        indexPath(CompletionKind.agent): [utf8.encode("{}")],
        extIndexPath(CompletionKind.skill): [
          utf8.encode("""{
  "upstream": {"repo": "$upstreamRepo"}
}""")
        ],
        extIndexPath(CompletionKind.agent): [utf8.encode("{}")],
      },
    );
    await settleIo(tester);
    expect(find.text("Could not reach the marketplace."), findsOneWidget);
  });

  testWidgets("a package the intake refuses is said so, and nothing lands",
      (tester) async {
    // Not a zip: the same bytes the .skill import refuses a picked file for.
    // The parse runs at load now, so the refusal is on the page — where the
    // install button would be dead — and the press never happens.
    await pumpList(tester, skillPackageBody: "PK-not-really");
    await openEntry(
      tester,
      kind: CompletionKind.skill,
      slug: "letterbox",
      until: find.textContaining("there is no SKILL.md in it"),
    );

    // No Install offered, the parser's reason where it would have been.
    expect(find.text("Install skill"), findsNothing);
    expect(find.textContaining("there is no SKILL.md in it"), findsOneWidget);
    final dir = p.join(app!.config.promptsDir(CompletionKind.skill), "letterbox");
    expect(Directory(dir).existsSync(), isFalse);
  });

  test("entries parse with version and tags absent", () {
    const body = {
      "py2": {"name": "py2", "description": "Python 2.", "author": "Someone"},
    };
    final entry = MarketplaceEntry.fromJson(
      body.keys.first,
      body["py2"]! as Map<String, Object?>,
    );
    expect(entry.version, isNull);
    expect(entry.tags, isEmpty);
  });
}