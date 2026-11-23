import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "package:agent_chat/app/marketplace/marketplace.dart";
import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";
import "package:entoli_core/model/models.dart";
import "package:agent_chat/providers.dart" show botAvatarPresetsProvider;
import "package:entoli_core/view/bot_avatar/bot_avatar_view.dart";
import "package:agent_chat/ui/marketplace/marketplace_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../data/fake_network.dart";
import "../fakes.dart" show onePixelPng;
import "../harness.dart";

const _letterboxMd =
    "---\nname: letterbox\ndescription: frames the reply\n---\n\nFrame it.\n";

Uint8List letterboxPackage() => packageSkillBytes(
  SkillPackage("letterbox", [
    ("SKILL.md", Uint8List.fromList(utf8.encode(_letterboxMd))),
    ("references/tone.md", Uint8List.fromList(utf8.encode("calm\n"))),
  ]),
);

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
    app = null;
  });

  String entryPath(CompletionKind kind, String slug, String file) =>
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/$slug/$file").path;

  String packagePath(CompletionKind kind, String slug) =>
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/$slug.skill").path;

  String indexPath(CompletionKind kind) =>
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/index.json").path;

  String extIndexPath(CompletionKind kind) =>
      Uri.parse("$marketplaceBaseUrl/ext/${kind.folder}/index.json").path;

  /// The skills' collection records, which group the remote skill.
  final collectionsPath = Uri.parse(
    "$marketplaceBaseUrl/skills/collections.json",
  ).path;

  String rawPath(String dir, String file) => Uri.parse(
    "https://raw.githubusercontent.com/$upstreamRepo/main/$dir/$file",
  ).path;

  /// An index naming a local and a remote skill and agent, the files they
  /// answer, and a collection holding the remote skill. [skillPackageBody]
  /// stands in for the `.skill` bytes; [agentPicture] is whether the local
  /// agent carries a `profile.png`.
  Map<String, List<List<int>>> site({
    String? skillPackageBody,
    bool agentPicture = true,
  }) => {
    indexPath(CompletionKind.skill): [
      utf8.encode("""{
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
}"""),
    ],
    indexPath(CompletionKind.agent): [
      utf8.encode("""{
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
}"""),
    ],
    extIndexPath(CompletionKind.skill): [
      utf8.encode("""{
  "upstream/red-letter": {
    "repo": "$upstreamRepo",
    "dir": "$upstreamSkillDir",
    "files": ["README.md", "SKILL.md", "references/tone.md"],
    "ref": "main"
  }
}"""),
    ],
    extIndexPath(CompletionKind.agent): [
      utf8.encode("""{
  "upstream/letter-writer": {
    "repo": "$upstreamRepo",
    "dir": "$upstreamAgentDir",
    "files": ["PROMPT.md", "README.md", "profile.png"],
    "ref": "main"
  }
}"""),
    ],
    collectionsPath: [
      utf8.encode(
        '{"upstream": {"name": "Upstream", "summary": "Letters from afar.", '
        '"members": ["upstream/red-letter"]}}',
      ),
    ],
    rawPath(upstreamSkillDir, "README.md"): [
      utf8.encode("# Red letter\n\nFrom upstream.\n"),
    ],
    rawPath(upstreamSkillDir, "SKILL.md"): [
      utf8.encode("""---
name: red-letter
description: Frames the reply from upstream.
metadata:
  author: The Upstream Authors
---

Frame it, from upstream.
"""),
    ],
    rawPath(upstreamSkillDir, "references/tone.md"): [utf8.encode("calm\n")],
    rawPath(upstreamAgentDir, "PROMPT.md"): [utf8.encode(_upstreamPrompt)],
    rawPath(upstreamAgentDir, "README.md"): [
      utf8.encode("# Letter writer\n\nWrites letters.\n"),
    ],
    rawPath(upstreamAgentDir, "profile.png"): [onePixelPng],
    entryPath(CompletionKind.skill, "letterbox", "README.md"): [
      utf8.encode("# Letterbox\n\nFrames the reply.\n"),
    ],
    packagePath(CompletionKind.skill, "letterbox"): [
      skillPackageBody != null
          ? utf8.encode(skillPackageBody)
          : letterboxPackage(),
    ],
    entryPath(CompletionKind.agent, "diary", "PROMPT.md"): [
      utf8.encode(_diaryPrompt),
    ],
    if (agentPicture)
      entryPath(CompletionKind.agent, "diary", "profile.png"): [onePixelPng],
  };

  /// Pumps [child] over the faked site. Inside `runAsync`: the fetch starts
  /// on the first frame, and a fetch mid-flight is the one thing `settleIo`
  /// cannot advance.
  Future<void> pumpMarket(
    WidgetTester tester, {
    Map<String, List<List<int>>>? bodies,
    Widget child = const MarketplacePage(),
  }) async {
    network.bodies.addAll(bodies ?? site());
    app = TestApp.create(marketplaceClient: network);
    // The rows' faces are an asset read, which a fake clock never lands.
    await tester.runAsync(
      () => app!.container.read(botAvatarPresetsProvider.future),
    );
    await tester.runAsync(() => app!.pump(tester, child, settle: false));
    await settleIo(tester, least: 10);
  }

  Finder installButton(CompletionKind kind) => find.widgetWithText(
    FilledButton,
    kind == CompletionKind.skill ? "Install skill" : "Install agent",
  );

  /// Opens [name]'s preview from the list, on its tab, and waits for it to
  /// load: its Install button, or [until].
  Future<void> openEntry(
    WidgetTester tester, {
    required CompletionKind kind,
    required String name,
    Finder? until,
  }) async {
    if (kind == CompletionKind.agent) {
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
    }
    await tester.tap(find.text(name));
    await pumpUntil(tester, until ?? installButton(kind));
    await settleIo(tester);
  }

  String skillDir(String name) =>
      p.join(app!.config.promptsDir(CompletionKind.skill), name);

  String agentsDir() => app!.config.promptsDir(CompletionKind.agent);

  testWidgets("collections first, then every entry in none", (tester) async {
    await pumpMarket(tester);

    expect(find.text("Collections · 1"), findsOneWidget);
    expect(find.text("Upstream"), findsOneWidget);
    expect(find.text("1 skill"), findsOneWidget);
    // Every member is another repository's, and the card says so.
    expect(find.text("External"), findsOneWidget);
    expect(find.text("Skills · 1"), findsOneWidget);
    expect(find.text("letterbox"), findsOneWidget);
    // A collection's member is not on the front page.
    expect(find.text("red-letter"), findsNothing);
    expect(
      tester.getTopLeft(find.text("Upstream")).dy <
          tester.getTopLeft(find.text("letterbox")).dy,
      isTrue,
    );

    // No agent collections: every agent is on the front page, no heading.
    await tester.tap(find.text("Agents"));
    await settleIo(tester);
    expect(find.text("diary"), findsOneWidget);
    expect(find.text("letter-writer"), findsOneWidget);
    expect(find.textContaining("Agents ·"), findsNothing);
  });

  testWidgets("a row says who made it, and an external one says so", (
    tester,
  ) async {
    await pumpMarket(tester, bodies: site()..remove(collectionsPath));

    expect(find.text("by Entoli Team · v1.0.0"), findsOneWidget);
    expect(find.text("by The Upstream Authors · v2.0.0"), findsOneWidget);
    expect(find.text("External"), findsOneWidget);
    expect(find.text("Collections · 1"), findsNothing);
  });

  testWidgets("rows wear a still face of their key", (tester) async {
    await pumpMarket(tester);
    final faces = tester.widgetList<BotAvatarView>(find.byType(BotAvatarView));
    expect(faces, isNotEmpty);
    expect(faces.every((face) => !face.animate), isTrue);
  });

  testWidgets("the search reaches into the collections", (tester) async {
    await pumpMarket(tester);

    await tester.enterText(find.byType(TextField), "upstream");
    await settleIo(tester);
    expect(find.text("Upstream"), findsWidgets);
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("letterbox"), findsNothing);

    // A member matching where its collection does not is still found.
    await tester.enterText(find.byType(TextField), "red");
    await settleIo(tester);
    expect(find.text("Collections · 1"), findsNothing);
    expect(find.text("Upstream · 1"), findsOneWidget);
    expect(find.text("red-letter"), findsOneWidget);

    await tester.enterText(find.byType(TextField), "nothing like it");
    await settleIo(tester);
    expect(find.text("Nothing matches \"nothing like it\"."), findsOneWidget);

    await tester.tap(find.byTooltip("Clear search"));
    await settleIo(tester);
    expect(find.text("letterbox"), findsOneWidget);
  });

  testWidgets("the filter icon ticks tags, and the list filters", (
    tester,
  ) async {
    await pumpMarket(tester, bodies: site()..remove(collectionsPath));

    await tester.tap(find.byTooltip("Filter by tag"));
    await settleIo(tester);
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text("1"), findsNWidgets(2));

    // The picker searches the tags.
    await tester.enterText(find.byType(TextField), " LAY");
    await settleIo(tester);
    expect(find.text("external"), findsNothing);
    await tester.enterText(find.byType(TextField), "zzz");
    await settleIo(tester);
    expect(find.text("No tag matches \"zzz\"."), findsOneWidget);
    await tester.enterText(find.byType(TextField), "");
    await settleIo(tester);

    await tester.tap(find.text("external"));
    await settleIo(tester);
    expect(find.text("Clear"), findsOneWidget);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.text("red-letter"), findsOneWidget);
    expect(find.text("letterbox"), findsNothing);

    // Ticking the other tag too intersects to nothing.
    await tester.tap(find.byTooltip("Filter by tag"));
    await settleIo(tester);
    await tester.tap(find.text("layout"));
    await settleIo(tester);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.text("Nothing matches here."), findsOneWidget);

    await tester.tap(find.byTooltip("Filter by tag"));
    await settleIo(tester);
    await tester.tap(find.text("Clear"));
    await settleIo(tester);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.text("letterbox"), findsOneWidget);
    expect(find.text("red-letter"), findsOneWidget);
  });

  testWidgets("a list no tag narrows has no filter", (tester) async {
    // One entry on the front page: its tag is every entry's.
    await pumpMarket(tester);
    expect(find.byTooltip("Filter by tag"), findsNothing);
  });

  testWidgets("a collection opens on its members, searched on their own", (
    tester,
  ) async {
    await pumpMarket(tester);
    await tester.tap(find.text("Upstream"));
    await settleIo(tester);

    expect(find.text("Marketplace · Skills"), findsOneWidget);
    expect(find.text("Letters from afar."), findsOneWidget);
    expect(find.text("red-letter"), findsOneWidget);
    // One member: no tag narrows it.
    expect(find.byTooltip("Filter by tag"), findsNothing);
    await tester.enterText(find.byType(TextField), "letterbox");
    await settleIo(tester);
    expect(find.text("red-letter"), findsNothing);
    expect(find.text("Nothing matches here."), findsOneWidget);
  });

  testWidgets("an unreachable marketplace says so and retries", (tester) async {
    await pumpMarket(tester, bodies: {});

    expect(find.text("Could not reach the marketplace."), findsOneWidget);
    expect(find.textContaining("HTTP 404"), findsOneWidget);

    network.bodies[indexPath(CompletionKind.skill)] = [utf8.encode("{}")];
    await tester.tap(find.text("Try again"));
    await settleIo(tester, least: 20, tries: 80);
    expect(find.text("The marketplace lists no skills yet."), findsOneWidget);
  });

  testWidgets("the sidebar opens it from its tile", (tester) async {
    await pumpMarket(
      tester,
      bodies: {
        indexPath(CompletionKind.skill): [utf8.encode("{}")],
        indexPath(CompletionKind.agent): [utf8.encode("{}")],
      },
      child: Scaffold(
        drawer: const Drawer(child: Sidebar()),
        appBar: AppBar(
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.menu));
    await settleIo(tester);
    await tester.tap(find.widgetWithText(ListTile, "Marketplace"));
    await settleIo(tester);
    expect(find.byType(MarketplacePage), findsOneWidget);
    expect(find.text("Agents"), findsOneWidget);
  });

  testWidgets("a skill's preview shows its README and files and installs", (
    tester,
  ) async {
    await pumpMarket(tester);
    await openEntry(tester, kind: CompletionKind.skill, name: "letterbox");

    expect(find.text("Marketplace · Skills"), findsOneWidget);
    expect(find.text("by Entoli Team"), findsOneWidget);
    expect(find.text("Letterbox"), findsOneWidget);
    await scrollTo(tester, find.text("references/tone.md"));
    expect(find.text("Install to"), findsOneWidget);

    await tester.tap(installButton(CompletionKind.skill));
    await settleIo(tester, least: 20, tries: 80);

    expect(
      File(p.join(skillDir("letterbox"), "SKILL.md")).readAsStringSync(),
      _letterboxMd,
    );
    expect(
      File(p.join(skillDir("letterbox"), "references", "tone.md")).existsSync(),
      isTrue,
    );
    expect(installButton(CompletionKind.skill), findsNothing);
    expect(find.text("Installed letterbox."), findsOneWidget);
  });

  testWidgets("installing over a skill asks, then replaces it whole", (
    tester,
  ) async {
    await pumpMarket(tester);
    final dir = skillDir("letterbox");
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, "SKILL.md")).writeAsStringSync("old\n");
    File(p.join(dir, "obsolete.sh")).writeAsStringSync("old\n");
    await openEntry(tester, kind: CompletionKind.skill, name: "letterbox");

    await tester.tap(installButton(CompletionKind.skill));
    await pumpUntil(tester, find.text("Replace"));
    await tester.tap(find.text("Replace"));
    await settleIo(tester, least: 20, tries: 80);

    expect(File(p.join(dir, "obsolete.sh")).existsSync(), isFalse);
    expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), _letterboxMd);
  });

  testWidgets("an agent's preview shows its picture and installs both", (
    tester,
  ) async {
    await pumpMarket(tester);
    await openEntry(tester, kind: CompletionKind.agent, name: "diary");

    expect(find.byType(Image), findsOneWidget);
    expect(find.text("Keeps a diary of what was done."), findsOneWidget);
    // The site serves no README for it, and an agent has no package files.
    expect(find.text("This entry ships no README."), findsOneWidget);
    expect(find.text("Files"), findsNothing);

    await tester.tap(installButton(CompletionKind.agent));
    await settleIo(tester, least: 20, tries: 80);

    expect(
      File(p.join(agentsDir(), "diary.md")).readAsStringSync(),
      _diaryPrompt,
    );
    expect(File(p.join(agentsDir(), "diary.png")).existsSync(), isTrue);
  });

  testWidgets("an agent with no picture installs the prompt alone", (
    tester,
  ) async {
    await pumpMarket(tester, bodies: site(agentPicture: false));
    await openEntry(tester, kind: CompletionKind.agent, name: "diary");

    expect(find.byType(Image), findsNothing);
    await tester.tap(installButton(CompletionKind.agent));
    await settleIo(tester, least: 20, tries: 80);

    expect(File(p.join(agentsDir(), "diary.md")).existsSync(), isTrue);
    expect(File(p.join(agentsDir(), "diary.png")).existsSync(), isFalse);
  });

  testWidgets("an entry's page sets its words apart from who made it", (
    tester,
  ) async {
    await pumpMarket(tester);
    await tester.tap(find.text("Upstream"));
    await settleIo(tester);
    await openEntry(tester, kind: CompletionKind.skill, name: "red-letter");

    expect(find.text("Description"), findsOneWidget);
    expect(
      find.text("Frames the reply from an upstream repository."),
      findsOneWidget,
    );
    expect(find.text("Author"), findsOneWidget);
    expect(find.text("The Upstream Authors"), findsOneWidget);
    expect(find.text("2.0.0"), findsOneWidget);
    expect(find.text("external"), findsOneWidget);
    expect(find.text("External"), findsOneWidget);
    await scrollTo(tester, find.text("From upstream."));

    await scrollTo(tester, find.text("$upstreamRepo/$upstreamSkillDir"));
    await tester.tap(find.text("$upstreamRepo/$upstreamSkillDir"));
    await tester.pump();
    expect(app!.linkOpener.opened, [
      Uri.parse("https://github.com/$upstreamRepo/tree/main/$upstreamSkillDir"),
    ]);

    await tester.tap(installButton(CompletionKind.skill));
    await settleIo(tester, least: 20, tries: 80);
    expect(
      File(p.join(skillDir("red-letter"), "README.md")).existsSync(),
      isTrue,
    );
  });

  testWidgets("a site's own entry has no source and no badge", (tester) async {
    await pumpMarket(tester);
    await openEntry(tester, kind: CompletionKind.skill, name: "letterbox");
    expect(find.text("Source"), findsNothing);
    expect(find.text("External"), findsNothing);
  });

  testWidgets("a remote agent installs under its directory's name", (
    tester,
  ) async {
    await pumpMarket(tester);
    await openEntry(tester, kind: CompletionKind.agent, name: "letter-writer");

    await tester.tap(installButton(CompletionKind.agent));
    await settleIo(tester, least: 20, tries: 80);
    expect(
      File(p.join(agentsDir(), "letter-writer.md")).readAsStringSync(),
      _upstreamPrompt,
    );
    expect(File(p.join(agentsDir(), "letter-writer.png")).existsSync(), isTrue);
  });

  testWidgets("a listing gone stale against its source has no Install", (
    tester,
  ) async {
    await pumpMarket(
      tester,
      bodies: site()
        ..remove(collectionsPath)
        ..remove(rawPath(upstreamSkillDir, "references/tone.md")),
    );
    await openEntry(
      tester,
      kind: CompletionKind.skill,
      name: "red-letter",
      until: find.textContaining("stale against the source"),
    );
    expect(installButton(CompletionKind.skill), findsNothing);
    expect(find.text("Install to"), findsNothing);
    expect(Directory(skillDir("red-letter")).existsSync(), isFalse);
  });

  testWidgets("a package the intake refuses is said so, with no Install", (
    tester,
  ) async {
    await pumpMarket(tester, bodies: site(skillPackageBody: "PK-not-really"));
    await openEntry(
      tester,
      kind: CompletionKind.skill,
      name: "letterbox",
      until: find.textContaining("there is no SKILL.md in it"),
    );
    expect(installButton(CompletionKind.skill), findsNothing);
    expect(Directory(skillDir("letterbox")).existsSync(), isFalse);
  });

  testWidgets("a malformed ext index is an unreachable marketplace", (
    tester,
  ) async {
    await pumpMarket(
      tester,
      bodies: {
        indexPath(CompletionKind.skill): [utf8.encode("{}")],
        extIndexPath(CompletionKind.skill): [
          utf8.encode('{"upstream": {"repo": "$upstreamRepo"}}'),
        ],
      },
    );
    expect(find.text("Could not reach the marketplace."), findsOneWidget);
  });
}
