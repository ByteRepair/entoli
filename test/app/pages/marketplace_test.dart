import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/app/marketplace/marketplace.dart";
import "package:agent_chat/app/pages/app_page.dart";
import "package:agent_chat/app/pages/marketplace.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";
import "package:agent_chat/domain/models.dart";

import "../../data/fake_network.dart";
import "../../fakes.dart" show FakeChatStore, onePixelPng;
import "../../harness.dart";
import "page_driver.dart";

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
  late TestApp app;
  late FakeNetwork network;

  setUp(() => network = FakeNetwork({}, missingAs404: true));
  tearDown(() {
    network.close();
    app.dispose();
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
  String rawPath(String dir, String file) => Uri.parse(
    "https://raw.githubusercontent.com/$upstreamRepo/main/$dir/$file",
  ).path;

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
    // The `.skill` the build serves — beside the entry's directories, at
    // the section root. The fixture's real package, or a body a test
    // asks to stand in for a malformed one.
    packagePath(CompletionKind.skill, "letterbox"): [
      skillPackageBody != null
          ? utf8.encode(skillPackageBody)
          : letterboxPackage(),
    ],
    entryPath(CompletionKind.agent, "diary", "README.md"): [
      utf8.encode("# Diary\n\nKeeps a diary.\n"),
    ],
    entryPath(CompletionKind.agent, "diary", "PROMPT.md"): [
      utf8.encode(_diaryPrompt),
    ],
    if (agentPicture)
      entryPath(CompletionKind.agent, "diary", "profile.png"): [onePixelPng],
  };

  /// Pumps the marketplace over the faked site, giving the fetches the real
  /// time they wait on. The pump itself is run inside `runAsync` because the
  /// fetch starts on the first frame, and a fetch mid-flight is the one thing
  /// `settleIo`, after it, cannot advance — and a second `runAsync` from
  /// outside is denied while it waits.

  void start([Map<String, List<List<int>>>? bodies]) {
    network.bodies.addAll(bodies ?? site());
    app = TestApp.create(marketplaceClient: network);
  }

  Future<PageDriver<MarketplaceAppPage>> list() async {
    final page = PageDriver(app, MarketplaceAppPage());
    await page.until(
      () =>
          page.find<CollectionController<MarketplaceEntry>>("local") != null ||
          page.find<NoticeController>("failed") != null,
    );
    return page;
  }

  List<String> names(PageDriver<MarketplaceAppPage> page, String part) =>
      page
          .find<CollectionController<MarketplaceEntry>>(part)
          ?.items
          .map((e) => e.name)
          .toList() ??
      const [];

  Future<PageDriver<MarketplaceEntryAppPage>> entry(
    CompletionKind kind,
    String slug,
  ) async {
    final all = await fetchMarketplaceEntries(network, kind);
    final page = PageDriver(
      app,
      MarketplaceEntryAppPage(
        kind: kind,
        entry: all.firstWhere((e) => e.slug == slug),
      ),
    );
    await page.until(() => page.find<NoticeController>("loading") == null);
    return page;
  }

  String skillDir(String name) =>
      p.join(app.config.promptsDir(CompletionKind.skill), name);

  test("the site's own entries first, the remote under External", () async {
    start();
    final page = await list();
    expect(names(page, "local"), ["letterbox"]);
    expect(names(page, "remote"), ["red-letter"]);
    await page
        .at<ChoiceController<CompletionKind>>("kind")
        .set(CompletionKind.agent);
    await page.until(() => names(page, "local").contains("diary"));
    expect(names(page, "remote"), ["letter-writer"]);
  });

  test("the search and the tags narrow the list in its order", () async {
    start();
    final page = await list();
    await page.at<TextController>("search").set("upstream");
    expect(names(page, "local"), isEmpty);
    expect(names(page, "remote"), ["red-letter"]);
    await page.at<TextController>("search").set("");
    await page.at<ActionController>("tags").run();
    final tags =
        page.app.container.read(appPagesProvider).last
            as MarketplaceTagsAppPage;
    final tagged = PageDriver(app, tags);
    await tagged.at<ToggleController>("tag-layout").set(true);
    expect(names(page, "local"), ["letterbox"]);
    expect(names(page, "remote"), isEmpty);
  });

  test(
    "an unreachable marketplace says so, and Try Again asks again",
    () async {
      start({});
      final page = await list();
      expect(page.find<NoticeController>("failed"), isNotNull);
      network.bodies.addAll(site());
      await page.at<ActionController>("retry").run();
      await page.until(() => names(page, "local").isNotEmpty);
    },
  );

  test("a skill previews its files and installs whole", () async {
    start();
    final page = await entry(CompletionKind.skill, "letterbox");
    expect(page.at<DocumentController>("readme").text, contains("Letterbox"));
    expect(page.at<InfoController>("files").rows.map((r) => r.title), [
      "references/tone.md",
    ]);
    final install = page.tool("install");
    expect(await install.confirm(), isNull);
    await install.run();
    expect(page.open, isFalse);
    expect(
      File(p.join(skillDir("letterbox"), "SKILL.md")).readAsStringSync(),
      _letterboxMd,
    );
    expect(
      File(p.join(skillDir("letterbox"), "references", "tone.md")).existsSync(),
      isTrue,
    );
  });

  test(
    "installing over a skill asks, then replaces it files and all",
    () async {
      start();
      Directory(skillDir("letterbox")).createSync(recursive: true);
      File(p.join(skillDir("letterbox"), "obsolete.sh")).writeAsStringSync("x");
      final page = await entry(CompletionKind.skill, "letterbox");
      final install = page.tool("install");
      expect((await install.confirm())?.confirmLabel, "Replace");
      await install.run();
      expect(
        File(p.join(skillDir("letterbox"), "obsolete.sh")).existsSync(),
        isFalse,
      );
    },
  );

  test(
    "an agent installs its prompt and its picture, or the prompt alone",
    () async {
      start();
      final agents = app.config.promptsDir(CompletionKind.agent);
      await (await entry(CompletionKind.agent, "diary")).tool("install").run();
      expect(File(p.join(agents, "diary.md")).readAsStringSync(), _diaryPrompt);
      expect(File(p.join(agents, "diary.png")).existsSync(), isTrue);
    },
  );

  test("an agent with no picture installs the prompt alone", () async {
    start(site(agentPicture: false));
    final agents = app.config.promptsDir(CompletionKind.agent);
    await (await entry(CompletionKind.agent, "diary")).tool("install").run();
    expect(File(p.join(agents, "diary.md")).existsSync(), isTrue);
    expect(File(p.join(agents, "diary.png")).existsSync(), isFalse);
  });

  test(
    "a remote skill previews out of its source and installs whole",
    () async {
      start();
      final page = await entry(CompletionKind.skill, "upstream/red-letter");
      expect(
        page.at<DocumentController>("readme").text,
        contains("From upstream."),
      );
      await page.tool("install").run();
      expect(
        File(p.join(skillDir("red-letter"), "README.md")).existsSync(),
        isTrue,
      );
    },
  );

  test("a listing gone stale against its source has no Install", () async {
    start(site()..remove(rawPath(upstreamSkillDir, "references/tone.md")));
    final page = await entry(CompletionKind.skill, "upstream/red-letter");
    expect(
      page.at<NoticeController>("problem").lines.single.text,
      contains("stale against the source"),
    );
    expect(page.findTool("install"), isNull);
    expect(Directory(skillDir("red-letter")).existsSync(), isFalse);
  });

  test("a package the intake refuses is said so, with no Install", () async {
    start(site(skillPackageBody: "not a zip"));
    final page = await entry(CompletionKind.skill, "letterbox");
    expect(page.find<NoticeController>("problem"), isNotNull);
    expect(page.findTool("install"), isNull);
  });

  test("a skill a turn drafted is previewed and installed", () async {
    final store = FakeChatStore()
      ..stageSkillInstall("chat-1", "install-1", letterboxPackage());
    app = TestApp.create(store: store);
    final page = PageDriver(
      app,
      SkillInstallAppPage(chatId: "chat-1", installId: "install-1"),
    );
    await page.until(() => page.findTool("install") != null);
    expect(page.at<DocumentController>("body").text, contains("Frame it."));
    await page.tool("install").run();
    expect(
      File(p.join(skillDir("letterbox"), "SKILL.md")).existsSync(),
      isTrue,
    );
  });

  test("the project picked is where the skill lands", () async {
    final store = FakeChatStore()
      ..stageSkillInstall("chat-1", "install-1", letterboxPackage());
    app = TestApp.create(store: store);
    await app.repo.createProject("work");
    final page = PageDriver(
      app,
      SkillInstallAppPage(chatId: "chat-1", installId: "install-1"),
    );
    await page.until(() => page.find<ChoiceController>("destination") != null);
    await page.until(
      () => page
          .at<ChoiceController<String>>("destination")
          .options
          .any((o) => o.value == "work"),
    );
    await page.at<ChoiceController<String>>("destination").set("work");
    await page.tool("install").run();
    expect(
      File(
        "${skillDirectory(app.config, "letterbox", project: "work")}/SKILL.md",
      ).existsSync(),
      isTrue,
    );
    expect(Directory(skillDir("letterbox")).existsSync(), isFalse);
  });

  test("a staged package that cannot be read says so", () async {
    start();
    final page = PageDriver(
      app,
      SkillInstallAppPage(chatId: "gone", installId: "nothing"),
    );
    await page.until(
      () =>
          page
              .find<NoticeController>("state")
              ?.lines
              .single
              .text
              .contains("could not be read") ??
          false,
    );
    expect(page.findTool("install"), isNull);
  });
}
