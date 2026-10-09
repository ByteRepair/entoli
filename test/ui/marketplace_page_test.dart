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

  /// An index naming one skill and one agent, and the files both answer.
  /// [skillPackageBody] stands in for the `.skill` bytes where a test wants
  /// a malformed one; [agentPicture] is whether the agent carries a
  /// `profile.png`.
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
  }
}""")],
        indexPath(CompletionKind.agent): [utf8.encode("""{
  "diary": {
    "name": "diary",
    "description": "Keeps a diary of what was done.",
    "author": "Entoli Team"
  }
}""")],
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

  testWidgets("tabs list the marketplace's skills and agents", (tester) async {
    await pumpList(tester);
    await settleIo(tester);

    expect(find.text("Skills"), findsWidgets);
    expect(find.text("Agents"), findsOneWidget);
    // Skills first, being the opening tab.
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("Frames the reply."), findsOneWidget);
    expect(find.text("Entoli Team · v1.0.0 · layout"), findsOneWidget);
    expect(find.text("diary"), findsNothing);

    await tester.tap(find.text("Agents"));
    await settleIo(tester);
    expect(find.text("diary"), findsOneWidget);
    expect(find.text("Keeps a diary of what was done."), findsOneWidget);
    expect(find.text("letterbox"), findsNothing);
  });

  testWidgets("an unreachable marketplace says so and retries", (tester) async {
    await pumpMarket(tester, const MarketplacePage());
    await settleIo(tester);

    expect(find.text("Could not reach the marketplace."), findsOneWidget);

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
    await tester.tap(find.text("letterbox"));
    await pumpUntil(tester, find.text("Install skill"));

    // The README, drawn as the entry's long description — the meta line is
    // the same one the list drew, both now on stage.
    expect(find.text("Letterbox"), findsOneWidget);
    expect(find.text("Entoli Team · v1.0.0 · layout"), findsNWidgets(2));
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

  testWidgets("an agent's preview shows the picture and installs prompt and picture",
      (tester) async {
    await pumpList(tester);
    await settleIo(tester);
    await tester.tap(find.text("Agents"));
    await settleIo(tester);
    await tester.tap(find.text("diary"));
    await pumpUntil(tester, find.text("Install agent"));
    await settleIo(tester);

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

  testWidgets("an agent with no picture installs the prompt alone",
      (tester) async {
    await pumpList(tester, agentPicture: false);
    await settleIo(tester);
    await tester.tap(find.text("Agents"));
    await settleIo(tester);
    await tester.tap(find.text("diary"));
    await pumpUntil(tester, find.text("Install agent"));
    await settleIo(tester);

    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text("Install agent"));
    await settleIo(tester, least: 20, tries: 80);

    final agentsDir = app!.config.promptsDir(CompletionKind.agent);
    expect(File(p.join(agentsDir, "diary.md")).readAsStringSync(), _diaryPrompt);
    // No picture served, none written.
    expect(File(p.join(agentsDir, "diary.png")).existsSync(), isFalse);
  });

  testWidgets("installing over an existing skill asks first, and Replace replaces",
      (tester) async {
    await pumpList(tester);
    await settleIo(tester);

    // A skill already installed under the same name, with a file the new
    // packaging would drop.
    final dir = p.join(app!.config.promptsDir(CompletionKind.skill), "letterbox");
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, "SKILL.md")).writeAsStringSync("old\n");
    File(p.join(dir, "obsolete.sh")).writeAsStringSync("old\n");

    await tester.tap(find.text("letterbox"));
    await pumpUntil(tester, find.text("Install skill"));

    await tester.tap(find.text("Install skill"));
    await pumpUntil(tester, find.text("Replace"));

    await tester.tap(find.text("Replace"));
    await settleIo(tester, least: 20, tries: 80);

    // The replace was wholesale: the dropped file is gone, the rest rewritten.
    expect(File(p.join(dir, "obsolete.sh")).existsSync(), isFalse);
    expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), _letterboxMd);
    expect(File(p.join(dir, "references", "tone.md")).existsSync(), isTrue);
  });

  testWidgets("a package the intake refuses is said so, and nothing lands",
      (tester) async {
    // Not a zip: the same bytes the .skill import refuses a picked file for.
    // The parse runs at load now, so the refusal is on the page — where the
    // install button would be dead — and the press never happens.
    await pumpList(tester, skillPackageBody: "PK-not-really");
    await settleIo(tester);
    await tester.tap(find.text("letterbox"));
    await pumpUntil(tester, find.textContaining("there is no SKILL.md in it"));
    await settleIo(tester);

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