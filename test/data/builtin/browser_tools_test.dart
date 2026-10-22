import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/browser/cdp_browser.dart"
    show challengeNote, looksLikeChallenge;
import "package:agent_chat/data/browser/helium.dart";
import "package:agent_chat/data/builtin/browser_tools.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

/// A tab that records what it was asked and answers with fixed text.
class FakeBrowserTab implements BrowserTab {
  final calls = <String>[];

  @override
  Future<String> goto(String url) async {
    calls.add("goto $url");
    return "page at $url";
  }

  @override
  Future<String> back() async {
    calls.add("back");
    return "back";
  }

  @override
  Future<String> click({int? ref, double? x, double? y}) async {
    calls.add("click ${ref ?? "($x, $y)"}");
    return "clicked";
  }

  @override
  Future<String> drag(
      ({double x, double y}) from, ({double x, double y}) to) async {
    calls.add("drag");
    return "dragged";
  }

  @override
  Future<String> type(int ref, String text, {bool submit = false}) async {
    calls.add("type $ref $text $submit");
    return "typed";
  }

  @override
  Future<String> scroll({bool up = false}) async {
    calls.add(up ? "scroll up" : "scroll down");
    return "scrolled";
  }

  @override
  Future<String> pageText({int offset = 0}) async {
    calls.add("text $offset");
    return "all of it";
  }

  @override
  Future<BrowserShot> screenshot({int? ref}) async {
    calls.add("shot ${ref ?? "view"}");
    return BrowserShot(Uint8List.fromList([1, 2, 3]), left: 10, top: 20);
  }

  @override
  Future<String> show() async {
    calls.add("show");
    return "shown";
  }

  @override
  Future<String> describeTarget({int? ref, double? x, double? y}) async =>
      '[$ref] button "Buy now" on https://shop.example/cart';
}

class _StubClassifier implements PermissionClassifier {
  _StubClassifier(this.decision);

  final PermissionDecision decision;
  final asked = <(String, String)>[];

  @override
  Future<PermissionDecision> classify(String toolName, String argumentsJson,
      {required String workspace, List<String> alsoWritable = const []}) async {
    asked.add((toolName, argumentsJson));
    return decision;
  }
}

LlmCompletion call(String name, Map<String, Object?> args) => LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: "",
        toolCalls: [
          LlmToolCall(id: "b-1", name: name, argumentsJson: jsonEncode(args)),
        ],
      ),
    );

void main() {
  final finish = saidOnly("done");

  BuiltinAgent agentOver(
    FakeLlmClient client, {
    BrowserTab? tab,
    bool browser = true,
    bool seesImages = true,
    bool hidden = false,
    bool oneShot = false,
    ApproveMode approveMode = ApproveMode.never,
    PermissionClassifier? classifier,
    FakeWebSearch? webSearch,
    List<ToolApproval>? asked,
  }) {
    final tempDir = Directory.systemTemp.createTempSync("agent-browser-test");
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final chat = p.join(tempDir.path, "chats", "chat-1");
    Directory(chat).createSync(recursive: true);
    return BuiltinAgent(
      session: BuiltinSession(),
      client: client,
      shell: FakeShell((_) => ok(""), canRunCommands: true),
      fs: fileSystemIo,
      workspace: chat,
      projectWorkspace: tempDir.path,
      model: "fake-model",
      approveMode: approveMode,
      approve: (approval) async {
        asked?.add(approval);
        return ApprovalResponse.allow;
      },
      answer: (request) => Future.value(request.unanswered),
      caps: AgentCapabilities.forTurn(
          commands: true, webSearch: true, disabled: const {}, browser: browser),
      browser: tab,
      seesImages: seesImages,
      browserHidden: hidden,
      oneShot: oneShot,
      classifier: classifier,
      webSearch: webSearch ?? FakeWebSearch(),
      saveResource: (filename, bytes) async => "res-$filename",
    );
  }

  List<String> offered(FakeLlmClient client) =>
      [for (final tool in client.calls.first.tools) tool.name];

  group("what is offered", () {
    test("the tools ride a picked browser, the screenshot a model that sees",
        () async {
      final seeing = FakeLlmClient([[finish]]);
      await agentOver(seeing, tab: FakeBrowserTab())
          .run(userMessage("hi"))
          .toList();
      expect(offered(seeing),
          containsAll([browserGotoToolName, browserScreenshotToolName]));

      final blind = FakeLlmClient([[finish]]);
      await agentOver(blind, tab: FakeBrowserTab(), seesImages: false)
          .run(userMessage("hi"))
          .toList();
      expect(offered(blind), contains(browserGotoToolName));
      expect(offered(blind), isNot(contains(browserScreenshotToolName)));
    });

    test("showing the window is offered only where it is hidden", () async {
      final hidden = FakeLlmClient([[finish]]);
      await agentOver(hidden, tab: FakeBrowserTab(), hidden: true)
          .run(userMessage("hi"))
          .toList();
      expect(offered(hidden), contains(browserShowToolName));

      final shown = FakeLlmClient([[finish]]);
      await agentOver(shown, tab: FakeBrowserTab())
          .run(userMessage("hi"))
          .toList();
      expect(offered(shown), isNot(contains(browserShowToolName)));
    });

    test("the prompt says how to use it only where it is offered", () {
      AgentCapabilities caps(bool browser) => AgentCapabilities.forTurn(
          commands: true, webSearch: true, disabled: const {}, browser: browser);
      expect(systemPrompt(platform: "linux", caps: caps(true)),
          contains("## Using the browser"));
      expect(systemPrompt(platform: "linux", caps: caps(false)),
          isNot(contains("browser_")));
    });

    test("nothing without a browser, and nothing for a sub-agent", () async {
      final off = FakeLlmClient([[finish]]);
      await agentOver(off, browser: false).run(userMessage("hi")).toList();
      expect(offered(off).where((n) => n.startsWith("browser_")), isEmpty);

      final worker = FakeLlmClient([[finish]]);
      await agentOver(worker, tab: FakeBrowserTab(), oneShot: true)
          .run(userMessage("hi"))
          .toList();
      expect(offered(worker).where((n) => n.startsWith("browser_")), isEmpty);
    });
  });

  group("gating", () {
    test("opening a page is a fetch of its URL to the classifier", () async {
      final tab = FakeBrowserTab();
      final classifier = _StubClassifier(PermissionDecision.deny);
      final events = await agentOver(
        FakeLlmClient([
          [call(browserGotoToolName, {"url": "https://example.com"})],
          [finish],
        ]),
        tab: tab,
        approveMode: ApproveMode.auto,
        classifier: classifier,
      ).run(userMessage("go")).toList();
      expect(tab.calls, isEmpty);
      expect(classifier.asked.single.$1, "webfetch");
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("Denied"));
    });

    test("a click is asked about by what it clicks, not its number", () async {
      final tab = FakeBrowserTab();
      final asked = <ToolApproval>[];
      await agentOver(
        FakeLlmClient([
          [call(browserClickToolName, {"ref": 7})],
          [finish],
        ]),
        tab: tab,
        approveMode: ApproveMode.ask,
        asked: asked,
      ).run(userMessage("buy")).toList();
      expect(asked.single.argumentsText, contains('button "Buy now"'));
      expect(tab.calls, ["click 7"]);
    });

    test("the classifier reads the described action", () async {
      final classifier = _StubClassifier(PermissionDecision.allow);
      await agentOver(
        FakeLlmClient([
          [call(browserTypeToolName, {"ref": 3, "text": "hi", "submit": true})],
          [finish],
        ]),
        tab: FakeBrowserTab(),
        approveMode: ApproveMode.auto,
        classifier: classifier,
      ).run(userMessage("type")).toList();
      final (tool, args) = classifier.asked.single;
      expect(tool, browserTypeToolName);
      expect(jsonDecode(args)["action"], contains("press Enter"));
    });

    test("reading and scrolling are not gated", () async {
      final tab = FakeBrowserTab();
      final asked = <ToolApproval>[];
      await agentOver(
        FakeLlmClient([
          [call(browserScrollToolName, {"direction": "up"})],
          [call(browserPageTextToolName, {"offset": 40})],
          [finish],
        ]),
        tab: tab,
        approveMode: ApproveMode.ask,
        asked: asked,
      ).run(userMessage("read")).toList();
      expect(asked, isEmpty);
      expect(tab.calls, ["scroll up", "text 40"]);
    });

    test("showing the window is not gated", () async {
      final tab = FakeBrowserTab();
      final asked = <ToolApproval>[];
      await agentOver(
        FakeLlmClient([
          [call(browserShowToolName, {})],
          [finish],
        ]),
        tab: tab,
        hidden: true,
        approveMode: ApproveMode.ask,
        asked: asked,
      ).run(userMessage("show")).toList();
      expect(asked, isEmpty);
      expect(tab.calls, ["show"]);
    });
  });

  test("a screenshot is an image on the result, with its offset", () async {
    final events = await agentOver(
      FakeLlmClient([
        [call(browserScreenshotToolName, {"ref": 4})],
        [finish],
      ]),
      tab: FakeBrowserTab(),
    ).run(userMessage("look")).toList();
    expect(events.whereType<ImageEvent>().single.part.resource,
        "res-screenshot.png");
    expect(events.whereType<ToolResultEvent>().first.result.output,
        contains("(10, 20)"));
  });

  group("webfetch's hint", () {
    Future<String> fetched(ShellResult result, {required bool browser}) async {
      final events = await agentOver(
        FakeLlmClient([
          [fetchCall("https://example.com")],
          [finish],
        ]),
        tab: browser ? FakeBrowserTab() : null,
        browser: browser,
        webSearch: FakeWebSearch(fetchResult: (_) => result),
      ).run(userMessage("fetch")).toList();
      final reported = events.whereType<ToolResultEvent>().first.result;
      return "${reported.output}${reported.exceptionInfo ?? ""}";
    }

    test("a refused fetch points at the browser where there is one", () async {
      const refused = ShellResult.failed("Fetch returned HTTP 403.");
      expect(await fetched(refused, browser: true),
          contains(browserGotoToolName));
      expect(await fetched(refused, browser: false),
          isNot(contains(browserGotoToolName)));
    });

    test("an ordinary page is left alone", () async {
      const page = ShellResult(returnCode: 0, output: "Some article text.");
      expect(await fetched(page, browser: true), "Some article text.");
    });
  });

  test("the settings are written only when not the default", () {
    expect(AppSettings().toJson().containsKey("agentBrowser"), isFalse);
    expect(AppSettings().toJson().containsKey("agentBrowserVisible"), isFalse);
    expect(AppSettings().agentBrowserVisible, isFalse);
    expect(
        AppSettings.fromJson(AppSettings(agentBrowserVisible: true).toJson())
            .agentBrowserVisible,
        isTrue);
    final picked = AppSettings(agentBrowser: embeddedBrowserId);
    expect(AppSettings.fromJson(picked.toJson()).agentBrowser, embeddedBrowserId);
  });

  test("Helium's assets are named as its releases name them", () {
    expect(heliumAsset(HeliumOs.linux, "0.20.1.1", arm: false),
        "helium-0.20.1.1-x86_64.AppImage");
    expect(heliumAsset(HeliumOs.macos, "0.20.1.1", arm: true),
        "helium_0.20.1.1_arm64-macos.dmg");
    expect(heliumAsset(HeliumOs.windows, "0.20.1.1", arm: false),
        "helium_0.20.1.1_x64-windows.zip");
  });

  group("a challenge", () {
    test("is a challenge frame, or a page saying it is one", () {
      expect(
          looksLikeChallenge("Shop", "", [
            "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x",
          ]),
          isTrue);
      expect(looksLikeChallenge("Just a moment...", "", const []), isTrue);
      expect(looksLikeChallenge("News", "Today's headlines", const []), isFalse);
    });

    test("tells the model it may ask the user", () {
      expect(challengeNote, contains("ask the user"));
    });
  });
}
