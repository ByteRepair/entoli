import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/foundation.dart" show ValueNotifier;
import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/browser/cdp_browser.dart"
    show CdpBrowser, challengeNote, looksLikeChallenge, pageAddress;
import "package:agent_chat/data/browser/helium.dart";
import "package:agent_chat/data/builtin/browser_tools.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart" show AgentCapability;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

/// A tab that records what it was asked and answers with fixed text.
class FakeBrowserTab implements BrowserTab {
  final calls = <String>[];

  @override
  final page = ValueNotifier<BrowserPage?>(null);

  @override
  Stream<BrowserFrame> frames() => const Stream.empty();

  @override
  Future<void> forward() async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> pointer(BrowserPointer event) async {}

  @override
  Future<void> key(BrowserKey event) async {}

  @override
  Future<void> insertText(String text) async {}

  @override
  Future<String?> selectedText() async => null;

  @override
  String? downloadDir;

  @override
  final ValueNotifier<BrowserHold?> hold = ValueNotifier(null);

  @override
  void hide(BrowserHold hold) {
    this.hold.value = hold;
    if (!hold.byAgent) notes.add("The user hid the browser from you.");
  }

  @override
  void unhide() {
    hold.value = null;
    notes.add("The user gave the browser back to you.");
  }

  final notes = <String>[];

  @override
  List<String> takeNotes() {
    final taken = [...notes];
    notes.clear();
    return taken;
  }

  @override
  Future<void> historyBack() async {}

  @override
  Future<String> upload(int ref, List<String> paths) async {
    calls.add("upload $ref ${paths.join(",")}");
    return "uploaded";
  }

  @override
  final ValueNotifier<UploadRequest?> uploadRequest = ValueNotifier(null);
  Completer<String>? _uploading;

  @override
  Future<String> requestUpload(int ref) {
    calls.add("request upload $ref");
    _uploading = Completer();
    uploadRequest.value = UploadRequest(target: "[$ref] button", url: "https://example.com");
    return _uploading!.future;
  }

  @override
  Future<void> submitUpload(List<String> paths) async {
    uploadRequest.value = null;
    _uploading!.complete("The user chose ${paths.length} file(s)");
  }

  @override
  void cancelUpload({String why = "The user cancelled the upload."}) {
    if (_uploading == null || _uploading!.isCompleted) return;
    uploadRequest.value = null;
    _uploading!.completeError(UploadCancelled(why));
  }

  @override
  final ValueNotifier<CredentialRequest?> credentialRequest = ValueNotifier(null);
  Completer<String>? _waiting;

  /// What a sign-in typed into the page, as the real tab would.
  final typedIn = <String>[];

  @override
  Future<String> requestCredentials(CredentialRequest request) {
    _waiting = Completer();
    credentialRequest.value = request;
    return _waiting!.future;
  }

  @override
  Future<void> submitCredentials(List<String> values) async {
    typedIn.addAll(values);
    credentialRequest.value = null;
    _waiting!.complete("signed in; page after");
  }

  @override
  void declineCredentials() {
    credentialRequest.value = null;
    _waiting!.completeError(const CredentialsDeclined("declined"));
  }

  @override
  void cancelCredentials() {
    credentialRequest.value = null;
    calls.add("cancelled");
  }

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
  Future<String> type(int? ref, String text, {bool submit = false}) async {
    calls.add("type $ref $text $submit");
    return "typed";
  }

  @override
  Future<String> press(String key, {Set<String> modifiers = const {}}) async {
    calls.add("press ${[...modifiers, key].join("+")}");
    return "pressed";
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
  Future<String> show({bool byUser = false}) async {
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
    bool noAsk = false,
    ApproveMode browserApprove = ApproveMode.never,
    BrowserUploadPolicy uploads = BrowserUploadPolicy.classifier,
    void Function(String chat)? inWorkspace,
    List<PermissionRule> permissions = const [],
    ApproveMode approveMode = ApproveMode.never,
    PermissionClassifier? classifier,
    FakeWebSearch? webSearch,
    List<ToolApproval>? asked,
  }) {
    final tempDir = Directory.systemTemp.createTempSync("agent-browser-test");
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final chat = p.join(tempDir.path, "chats", "chat-1");
    Directory(chat).createSync(recursive: true);
    inWorkspace?.call(chat);
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
          commands: true,
          webSearch: true,
          disabled: {if (noAsk) AgentCapability.ask},
          browser: browser),
      browser: tab,
      seesImages: seesImages,
      browserHidden: hidden,
      browserApprove: browserApprove,
      browserUploads: uploads,
      permissions: permissions,
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
        browserApprove: ApproveMode.auto,
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
        browserApprove: ApproveMode.ask,
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
        browserApprove: ApproveMode.auto,
        classifier: classifier,
      ).run(userMessage("type")).toList();
      final (tool, args) = classifier.asked.single;
      expect(tool, browserTypeToolName);
      expect(jsonDecode(args)["action"], contains("press Enter"));
    });

    test("by default nothing in the browser asks, whatever the chat's mode",
        () async {
      final tab = FakeBrowserTab();
      final asked = <ToolApproval>[];
      await agentOver(
        FakeLlmClient([
          [call(browserGotoToolName, {"url": "https://example.com"})],
          [call(browserClickToolName, {"ref": 7})],
          [call(browserTypeToolName, {"text": "hi"})],
          [finish],
        ]),
        tab: tab,
        approveMode: ApproveMode.ask,
        asked: asked,
      ).run(userMessage("go")).toList();
      expect(asked, isEmpty);
      expect(tab.calls, ["goto https://example.com", "click 7", "type null hi false"]);
    });

    test("a host the user denied stays denied when nothing asks", () async {
      final tab = FakeBrowserTab();
      final events = await agentOver(
        FakeLlmClient([
          [call(browserGotoToolName, {"url": "https://blocked.example/x"})],
          [finish],
        ]),
        tab: tab,
        permissions: const [
          PermissionRule(
              tool: "webfetch",
              pattern: "blocked.example",
              decision: PermissionDecision.deny),
        ],
      ).run(userMessage("go")).toList();
      expect(tab.calls, isEmpty);
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("Denied"));
    });

    test("a key press carries its modifiers", () async {
      final tab = FakeBrowserTab();
      await agentOver(
        FakeLlmClient([
          [
            call(browserPressToolName, {
              "key": "b",
              "modifiers": ["Control"],
            }),
          ],
          [finish],
        ]),
        tab: tab,
      ).run(userMessage("bold")).toList();
      expect(tab.calls, ["press Control+b"]);
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
        browserApprove: ApproveMode.ask,
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

  group("private input", () {
    test("while hidden, every browser tool refuses and touches nothing",
        () async {
      final tab = FakeBrowserTab()..hide(const BrowserHold());
      final events = await agentOver(
        FakeLlmClient([
          [call(browserGotoToolName, {"url": "https://example.com"})],
          [call(browserScreenshotToolName, {})],
          [finish],
        ]),
        tab: tab,
      ).run(userMessage("go")).toList();
      expect(tab.calls, isEmpty);
      final refused = events.whereType<ToolResultEvent>().toList();
      expect(refused, hasLength(2));
      for (final result in refused) {
        expect(result.result.exceptionInfo, contains("hidden the browser"));
      }
    });

    test("a sign-in reaches the page, and nothing the agent sees holds it",
        () async {
      final tab = FakeBrowserTab();
      tab.credentialRequest.addListener(() {
        if (tab.credentialRequest.value != null) {
          unawaited(tab.submitCredentials(["me@example.com", "hunter2"]));
        }
      });
      final client = FakeLlmClient([
        [
          call(browserCredentialsPromptToolName, {
            "reason": "Sign in to Example",
            "fields": [
              {"ref": 3, "label": "Email"},
              {"ref": 4, "label": "Password", "secret": true},
            ],
            "submit": [
              {"ref": 5},
            ],
          }),
        ],
        [finish],
      ]);
      final events =
          await agentOver(client, tab: tab).run(userMessage("sign in")).toList();
      expect(tab.typedIn, ["me@example.com", "hunter2"]);
      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("page after"));
      // Not in a single event the log could record, nor in what the model
      // was sent next.
      for (final event in events) {
        expect(_describe(event), isNot(contains("hunter2")));
      }
      expect(client.sent.last.map((m) => m.text).join(),
          isNot(contains("hunter2")));
    });

    test("a declined sign-in is a failure the agent reads", () async {
      final tab = FakeBrowserTab();
      tab.credentialRequest.addListener(() {
        if (tab.credentialRequest.value != null) tab.declineCredentials();
      });
      final events = await agentOver(
        FakeLlmClient([
          [
            call(browserCredentialsPromptToolName, {
              "reason": "Sign in",
              "fields": [
                {"ref": 1, "label": "Email"},
              ],
            }),
          ],
          [finish],
        ]),
        tab: tab,
      ).run(userMessage("sign in")).toList();
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          "declined");
    });

    test("hiding shows the reason and waits for the browser back", () async {
      final tab = FakeBrowserTab();
      String? shown;
      tab.hold.addListener(() {
        final hold = tab.hold.value;
        if (hold != null) {
          shown = hold.reason;
          // The user signs in, then gives it back.
          scheduleMicrotask(tab.unhide);
        }
      });
      final events = await agentOver(
        FakeLlmClient([
          [
            call(browserCredentialsHideToolName,
                {"reason": "Please sign in to Google to proceed"}),
          ],
          [finish],
        ]),
        tab: tab,
      ).run(userMessage("go")).toList();
      expect(shown, "Please sign in to Google to proceed");
      expect(tab.hold.value, isNull);
      expect(events.whereType<ToolResultEvent>().first.result.output,
          contains("The user gave the browser back to you."));
    });

    test("what the user did reaches the next browser result, once",
        () async {
      final tab = FakeBrowserTab()
        ..notes.addAll([
          "The user went back to https://example.com/.",
          "The user quit the browser.",
        ]);
      final events = await agentOver(
        FakeLlmClient([
          [call(browserScrollToolName, {})],
          [call(browserScrollToolName, {})],
          [finish],
        ]),
        tab: tab,
      ).run(userMessage("go")).toList();
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results.first.result.output,
          startsWith("Since your last browser call:\n- The user went back"));
      expect(results.first.result.output, contains("- The user quit the browser."));
      expect(results.first.result.output, endsWith("scrolled"));
      expect(results.last.result.output, "scrolled");
    });

    test("a refusal while hidden carries the note that hid it", () async {
      final tab = FakeBrowserTab()..hide(const BrowserHold());
      final events = await agentOver(
        FakeLlmClient([
          [call(browserScrollToolName, {})],
          [finish],
        ]),
        tab: tab,
      ).run(userMessage("go")).toList();
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("The user hid the browser from you."));
    });

    test("neither is offered where nobody is there to answer", () async {
      final client = FakeLlmClient([[finish]]);
      await agentOver(client, tab: FakeBrowserTab(), noAsk: true)
          .run(userMessage("hi"))
          .toList();
      expect(offered(client), contains(browserGotoToolName));
      expect(offered(client), isNot(contains(browserCredentialsPromptToolName)));
      expect(offered(client), isNot(contains(browserCredentialsHideToolName)));
    });
  });

  group("uploads", () {
    void report(String chat) =>
        File(p.join(chat, "report.pdf")).writeAsStringSync("%PDF");

    LlmCompletion upload() => call(browserUploadToolName, {
          "ref": 4,
          "paths": ["report.pdf"],
        });

    test("by default the classifier sees the whole path and the page",
        () async {
      final tab = FakeBrowserTab();
      final classifier = _StubClassifier(PermissionDecision.deny);
      final events = await agentOver(
        FakeLlmClient([
          [upload()],
          [finish],
        ]),
        tab: tab,
        classifier: classifier,
        inWorkspace: report,
      ).run(userMessage("upload it")).toList();
      expect(tab.calls, isEmpty);
      final (tool, args) = classifier.asked.single;
      expect(tool, browserUploadToolName);
      final action = jsonDecode(args)["action"] as String;
      expect(action, contains(p.join("chats", "chat-1", "report.pdf")));
      expect(action, contains("shop.example/cart"));
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("Denied"));
    });

    test("it is its own scope: clicks unasked, an upload still asked",
        () async {
      final tab = FakeBrowserTab();
      final classifier = _StubClassifier(PermissionDecision.allow);
      await agentOver(
        FakeLlmClient([
          [call(browserClickToolName, {"ref": 1})],
          [upload()],
          [finish],
        ]),
        tab: tab,
        classifier: classifier,
        inWorkspace: report,
      ).run(userMessage("go")).toList();
      // The click asked nobody; only the upload reached the classifier.
      expect([for (final (tool, _) in classifier.asked) tool],
          [browserUploadToolName]);
      expect(tab.calls.last, startsWith("upload 4 "));
      expect(tab.calls.last, endsWith("report.pdf"));
    });

    test("Don't ask uploads with nobody asked", () async {
      final tab = FakeBrowserTab();
      final classifier = _StubClassifier(PermissionDecision.deny);
      await agentOver(
        FakeLlmClient([
          [upload()],
          [finish],
        ]),
        tab: tab,
        classifier: classifier,
        uploads: BrowserUploadPolicy.allow,
        inWorkspace: report,
      ).run(userMessage("upload it")).toList();
      expect(classifier.asked, isEmpty);
      expect(tab.calls.single, startsWith("upload 4 "));
    });

    test("a file that is not there is refused before anything", () async {
      final tab = FakeBrowserTab();
      final events = await agentOver(
        FakeLlmClient([
          [upload()],
          [finish],
        ]),
        tab: tab,
        uploads: BrowserUploadPolicy.allow,
      ).run(userMessage("upload it")).toList();
      expect(tab.calls, isEmpty);
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("no file at report.pdf"));
    });

    test("where the user chooses, the agent names no file and waits",
        () async {
      final tab = FakeBrowserTab();
      tab.uploadRequest.addListener(() {
        if (tab.uploadRequest.value != null) {
          unawaited(tab.submitUpload(["/home/me/cv.pdf"]));
        }
      });
      final client = FakeLlmClient([
        [call(browserUploadToolName, {"ref": 4})],
        [finish],
      ]);
      final events = await agentOver(client,
              tab: tab, uploads: BrowserUploadPolicy.user)
          .run(userMessage("upload my cv"))
          .toList();
      final schema = client.calls.first.tools
          .firstWhere((t) => t.name == browserUploadToolName)
          .schema;
      expect((schema["properties"] as Map).containsKey("paths"), isFalse);
      expect(tab.calls, ["request upload 4"]);
      expect(events.whereType<ToolResultEvent>().first.result.output,
          contains("The user chose 1 file(s)"));
    });

    test("and a cancel is what the agent hears", () async {
      final tab = FakeBrowserTab();
      tab.uploadRequest.addListener(() {
        if (tab.uploadRequest.value != null) {
          tab.cancelUpload(why: "The user sent a message instead.");
        }
      });
      final events = await agentOver(
        FakeLlmClient([
          [call(browserUploadToolName, {"ref": 4})],
          [finish],
        ]),
        tab: tab,
        uploads: BrowserUploadPolicy.user,
      ).run(userMessage("upload my cv")).toList();
      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("sent a message instead"));
    });

    test("where the user chooses, nobody there means no tool", () async {
      final client = FakeLlmClient([[finish]]);
      await agentOver(client,
              tab: FakeBrowserTab(),
              uploads: BrowserUploadPolicy.user,
              noAsk: true)
          .run(userMessage("hi"))
          .toList();
      expect(offered(client), isNot(contains(browserUploadToolName)));
    });

    test("the policy is written only when not the classifier", () {
      expect(AppSettings().toJson().containsKey("agentBrowserUploads"), isFalse);
      expect(
          AppSettings.fromJson(
                  AppSettings(agentBrowserUploads: BrowserUploadPolicy.user)
                      .toJson())
              .agentBrowserUploads,
          BrowserUploadPolicy.user);
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

  test("a quit ends the hiding and any sign-in waiting on the user", () async {
    final dir = Directory.systemTemp.createTempSync("agent-browser-quit");
    addTearDown(() => dir.deleteSync(recursive: true));
    final browser = CdpBrowser(
      browserDir: dir.path,
      picked: () => null,
      embedded: HeliumDownload(dir.path),
      visible: () => false,
    );
    final tab = browser.tab("chat-1");
    tab.hide(const BrowserHold(reason: "Sign in to Google"));
    final waiting = tab.requestCredentials(const CredentialRequest(
        reason: "Sign in", fields: [CredentialField(ref: 1, label: "Email")]));
    // Listened to before the quit fails it, as the waiting agent is.
    final declined = expectLater(waiting, throwsA(isA<CredentialsDeclined>()));
    await browser.close();
    expect(tab.hold.value, isNull);
    expect(tab.credentialRequest.value, isNull);
    await declined;
  });

  test("deleting the browser's data takes the profile, not the download",
      () async {
    final dir = Directory.systemTemp.createTempSync("agent-browser-clear");
    addTearDown(() => dir.deleteSync(recursive: true));
    File("${dir.path}/profile/Default/Cookies").createSync(recursive: true);
    File("${dir.path}/download/kept").createSync(recursive: true);
    final browser = CdpBrowser(
      browserDir: dir.path,
      picked: () => null,
      embedded: HeliumDownload(dir.path),
      visible: () => false,
    );
    final tab = browser.tab("chat-1");
    tab.hide(const BrowserHold(reason: "Sign in to Google"));
    await browser.clearData();
    expect(Directory("${dir.path}/profile").existsSync(), isFalse);
    expect(File("${dir.path}/download/kept").existsSync(), isTrue);
    expect(tab.hold.value, isNull);
  });

  test("Helium's assets are named as its releases name them", () {
    expect(heliumAsset(HeliumOs.linux, "0.20.1.1", arm: false),
        "helium-0.20.1.1-x86_64.AppImage");
    expect(heliumAsset(HeliumOs.macos, "0.20.1.1", arm: true),
        "helium_0.20.1.1_arm64-macos.dmg");
    expect(heliumAsset(HeliumOs.windows, "0.20.1.1", arm: false),
        "helium_0.20.1.1_x64-windows.zip");
  });

  test("an address with no scheme is https, or http on this machine", () {
    expect(pageAddress("example.com/a"), "https://example.com/a");
    expect(pageAddress("localhost:8080"), "http://localhost:8080");
    expect(pageAddress("127.0.0.1:3000/x"), "http://127.0.0.1:3000/x");
    expect(pageAddress("localhost.example.com"), "https://localhost.example.com");
    expect(pageAddress("http://localhost:8080"), "http://localhost:8080");
    expect(pageAddress("about:blank"), "about:blank");
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

/// An event as far as anything could record it: its call's arguments and its
/// result's text.
String _describe(AgentEvent event) => switch (event) {
      ToolCallEvent(:final call) => "${call.argumentsJson} ${call.argumentsText}",
      ToolResultEvent(:final result) =>
        "${result.output} ${result.exceptionInfo}",
      _ => "$event",
    };
