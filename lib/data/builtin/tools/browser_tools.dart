import "dart:async";
import "dart:convert";

import "../../../domain/agent_backend.dart";
import "../../../domain/agent_browser.dart";
import "../../../domain/permission.dart";
import "../../../domain/shell.dart";
import "../../../domain/tool_arg.dart";
import "../../../domain/web_search.dart" show webfetchToolName;
import "../approval_gate.dart";
import "../llm/llm_client.dart";
import "../templates.dart" show notExecuted, systemProse;
import "agent_tool.dart";
import "turn.dart";

/// The browser tools, offered where Settings > Agent Browser has picked one,
/// on a top-level turn — a fan-out of workers on one window would navigate
/// each other's pages. Every one but the screenshot answers with the page as
/// the call left it: what is in view, its interactive elements numbered for
/// `browser_click` and `browser_type`. See "The browser" in AGENTS.md.
const browserGotoToolName = "browser_goto_url";
const browserSearchToolName = "browser_search";
const browserClickToolName = "browser_click";
const browserTypeToolName = "browser_type";
const browserDragToolName = "browser_drag";
const browserScrollToolName = "browser_scroll";
const browserBackToolName = "browser_back";
const browserPageTextToolName = "browser_page_text";
const browserScreenshotToolName = "browser_screenshot";
const browserPressToolName = "browser_press";
const browserCredentialsPromptToolName = "browser_credentials_prompt";
const browserCredentialsHideToolName = "browser_credentials_hide";
const browserUploadToolName = "browser_upload";

const _point = {
  "type": "object",
  "properties": {
    "x": {"type": "number"},
    "y": {"type": "number"},
  },
  "required": ["x", "y"],
};

/// What every browser tool shares: offered where the turn has a browser,
/// refused while the user has it, and answered under whatever happened in it
/// that this agent did not do since its last call.
abstract class BrowserTool extends AgentTool {
  BrowserTool(super.offer);

  @override
  bool get offered => offer.caps.browser;

  /// The refusal every browser tool answers with while the user holds the
  /// browser, or null where it is the agent's.
  static Stream<AgentEvent>? refusedWhileHeld(LlmToolCall call, Turn turn) =>
      turn.browser!.hold.value == null
          ? null
          : toolRejected(call, noted(turn, _hidden));

  static const _hidden = "The user has hidden the browser from you to do "
      "something private in it, such as signing in. Do not retry yet: carry "
      "on with something else, or ask the user and wait for them to say they "
      "have handed it back.";

  /// [text] under what happened in the browser that this agent did not do
  /// since its last browser call — the user's back and forward, their hiding
  /// and giving back, the browser quitting. A turn is never handed a
  /// message mid-flight, so the next browser result is where the agent
  /// hears of it, and the log keeps it there.
  static String noted(Turn turn, String text) {
    final notes = turn.browser?.takeNotes() ?? const [];
    if (notes.isEmpty) return text;
    return "Since your last browser call:\n"
        "${notes.map((note) => "- $note").join("\n")}\n\n$text";
  }

  /// [outcome] as [call]'s result, under what happened since the last.
  static ToolResultEvent result(LlmToolCall call, Turn turn, GateOutcome outcome) {
    final result = outcome.result!;
    outcome.result = result.returnCode == 0
        ? ShellResult(returnCode: 0, output: noted(turn, result.output))
        : ShellResult.failed(noted(turn, result.exceptionInfo ?? result.output));
    return ToolResultEvent(outcome.resultOf(call));
  }

  /// [call] as the banner and the classifier read it: what it does to which
  /// element on which page, which the model's own `{"ref": 12}` says
  /// nothing about.
  static LlmToolCall described(LlmToolCall call, String described) =>
      LlmToolCall(
          id: call.id,
          name: call.name,
          argumentsJson: jsonEncode({"action": described}));

  /// [run]'s text as a result, a throw as a failed one.
  static Future<ShellResult> Function() attempt(Future<String> Function() run) =>
      () async {
        try {
          return ShellResult(returnCode: 0, output: await run());
        } catch (e) {
          return ShellResult.failed("$e");
        }
      };
}

/// One step on the page, worked out of a call's arguments: what the label
/// shows, what it does, and what gates it.
class PageStep {
  const PageStep(this.label, this.run, {this.navigate, this.acting, this.target});

  final String label;
  final Future<String> Function() run;

  /// The address a page is opened at: gated as a fetch of it, by the same
  /// network rules.
  final String? navigate;

  /// What it does to the page — a click, a typed field, a key or a drag —
  /// which is gated the way a command is, worded with [target] so the banner
  /// and the classifier read an element rather than a number.
  final String? acting;
  final Future<String> Function()? target;
}

/// A browser tool that does one thing to the page and answers with the page
/// as the call left it. Opening a page is gated as a fetch, acting on one as
/// a command; moving about a page and reading it are not gated.
abstract class PageTool extends BrowserTool {
  PageTool(super.offer);

  /// What the model is told when [step] finds the arguments are not what the
  /// tool takes.
  String get usage => "The $name tool's arguments were not what it takes.";

  /// The step [args] ask for, or null where they are not what the tool takes.
  PageStep? step(Map<String, dynamic> args, BrowserTab tab);

  /// A non-empty string argument, as [stringArg] reads one.
  static String? string(Map<String, dynamic> args, String key) =>
      args[key] is String && (args[key] as String).isNotEmpty
          ? args[key] as String
          : null;

  static int? ref(Map<String, dynamic> args) =>
      args["ref"] is int ? args["ref"] as int : null;

  static double? number(Object? value) => value is num ? value.toDouble() : null;

  static ({double x, double y})? point(Object? value) {
    if (value is! Map) return null;
    final x = number(value["x"]), y = number(value["y"]);
    return x == null || y == null ? null : (x: x, y: y);
  }

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final tab = turn.browser!;
    if (BrowserTool.refusedWhileHeld(call, turn) case final refused?) {
      yield* refused;
      return;
    }
    final step = this.step(decodeArgs(call.argumentsJson) ?? const {}, tab);
    if (step == null) {
      yield* toolRejected(call, usage);
      return;
    }
    yield toolCalled(call, step.label);
    final attempt = BrowserTool.attempt(step.run);
    final outcome = GateOutcome();
    final navigate = step.navigate, acting = step.acting;
    if (navigate != null) {
      yield* turn.gate.decide(call, webfetchToolName, attempt, outcome,
          argumentsText: navigate, ruleSubject: navigate, mode: turn.browserApprove);
    } else if (acting != null) {
      final String target;
      try {
        target = await step.target!();
      } catch (e) {
        yield toolFailed(call, "$e");
        return;
      }
      final described = "$acting $target";
      yield* turn.gate.decide(
          BrowserTool.described(call, described), name, attempt, outcome,
          argumentsText: described, mode: turn.browserApprove);
    } else {
      outcome.result = await attempt();
    }
    yield BrowserTool.result(call, turn, outcome);
  }
}

/// Open an address. Carries the browser's words in the prompt for the group.
class BrowserGotoTool extends PageTool {
  BrowserGotoTool(super.offer);

  @override
  String get name => browserGotoToolName;

  @override
  String get runningLabel => "Opening a page";

  @override
  String get fragment => "`browser_*` to use a web page in the browser";

  @override
  String get section => systemProse("agent-browser");

  @override
  String get description => "Open a URL in the browser, a real one with the "
      "user's window and logins, and return what is in view. Use it over "
      "`webfetch` for a page that needs JavaScript, a login, or one that "
      "refused `webfetch`.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "url": {"type": "string", "description": "The URL to open."},
        },
        "required": ["url"],
      };

  @override
  String get usage => 'The $browserGotoToolName tool takes {"url": "..."}.';

  @override
  PageStep? step(Map<String, dynamic> args, BrowserTab tab) {
    final url = PageTool.string(args, "url");
    if (url == null) return null;
    return PageStep(url, () => tab.goto(url), navigate: url);
  }
}

class BrowserSearchTool extends PageTool {
  BrowserSearchTool(super.offer);

  @override
  String get name => browserSearchToolName;

  @override
  String get runningLabel => "Opening a page";

  @override
  String get description =>
      "Search the web in the browser and return the results page.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "The search query."},
        },
        "required": ["query"],
      };

  @override
  String get usage => 'The $browserSearchToolName tool takes {"query": "..."}.';

  @override
  PageStep? step(Map<String, dynamic> args, BrowserTab tab) {
    final query = PageTool.string(args, "query");
    if (query == null) return null;
    return PageStep(query,
        () => tab.goto(Uri.https("duckduckgo.com", "/", {"q": query}).toString()));
  }
}

class BrowserClickTool extends PageTool {
  BrowserClickTool(super.offer);

  @override
  String get name => browserClickToolName;

  @override
  String get description => "Click an element by its number from the last "
      "page description, or a point by x and y in viewport pixels (what a "
      "screenshot shows). Use x and y for what has no number, such as the "
      "inside of a frame. A file the page downloads is saved into "
      "`downloads/` in your workspace, and a later browser result says when "
      "it has arrived.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "ref": {"type": "integer", "description": "The element's number."},
          "x": {"type": "number"},
          "y": {"type": "number"},
        },
      };

  @override
  String get usage =>
      'The $browserClickToolName tool takes {"ref": n} or {"x": n, "y": n}.';

  @override
  PageStep? step(Map<String, dynamic> args, BrowserTab tab) {
    final at = PageTool.ref(args);
    final x = PageTool.number(args["x"]), y = PageTool.number(args["y"]);
    if (at == null && (x == null || y == null)) return null;
    return PageStep(at != null ? "[$at]" : "($x, $y)",
        () => tab.click(ref: at, x: x, y: y),
        acting: "click", target: () => tab.describeTarget(ref: at, x: x, y: y));
  }
}

class BrowserTypeTool extends PageTool {
  BrowserTypeTool(super.offer);

  @override
  String get name => browserTypeToolName;

  @override
  String get runningLabel => "Typing";

  @override
  String get description => "Type text. With `ref`, replaces the text in that "
      "field (on a select, picks the option whose label matches). Without "
      "`ref`, types at whatever has focus, key by key, as a keyboard does: "
      "what an editor that draws its own text needs, such as Google Docs or "
      "Slides, where you first click into the text and then type with no "
      "`ref`. A newline is Enter. Set `submit` to press Enter after.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "ref": {
            "type": "integer",
            "description": "The field's number; leave out to type at the focus.",
          },
          "text": {"type": "string"},
          "submit": {"type": "boolean"},
        },
        "required": ["text"],
      };

  @override
  String get usage => 'The $browserTypeToolName tool takes {"text": "..."}, '
      'and a "ref" to type into that field.';

  @override
  PageStep? step(Map<String, dynamic> args, BrowserTab tab) {
    final at = PageTool.ref(args);
    final text = args["text"];
    if (text is! String) return null;
    final submit = args["submit"] == true;
    return PageStep(at == null ? text : "[$at] $text",
        () => tab.type(at, text, submit: submit),
        acting: submit ? "type \"$text\" and press Enter in" : "type \"$text\" in",
        target: () => tab.describeTarget(
            ref: at, x: PageTool.number(args["x"]), y: PageTool.number(args["y"])));
  }
}

class BrowserPressTool extends PageTool {
  BrowserPressTool(super.offer);

  @override
  String get name => browserPressToolName;

  @override
  String get runningLabel => "Typing";

  @override
  String get description => "Press one key at the focus, optionally with "
      "modifiers held: Enter, Tab, Escape, Backspace, an arrow, or a shortcut "
      "such as Control+b for bold or Control+a to select all (Meta on a Mac "
      "site that wants Cmd).";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "key": {
            "type": "string",
            "description": "The DOM key name (Enter, Tab, Escape, Backspace, "
                "Delete, ArrowDown, Home, PageDown, F5) or one character.",
          },
          "modifiers": {
            "type": "array",
            "items": {
              "type": "string",
              "enum": ["Control", "Shift", "Alt", "Meta"],
            },
          },
        },
        "required": ["key"],
      };

  @override
  String get usage => 'The $browserPressToolName tool takes {"key": "Enter"}, '
      'and "modifiers": ["Control"] to hold any.';

  @override
  PageStep? step(Map<String, dynamic> args, BrowserTab tab) {
    final key = PageTool.string(args, "key");
    if (key == null) return null;
    final held = {
      for (final modifier in (args["modifiers"] as List? ?? const []))
        if (modifier is String) modifier,
    };
    final label = [...held, key].join("+");
    return PageStep(label, () => tab.press(key, modifiers: held),
        acting: "press $label in",
        target: () => tab.describeTarget(
            ref: PageTool.ref(args),
            x: PageTool.number(args["x"]),
            y: PageTool.number(args["y"])));
  }
}

class BrowserDragTool extends PageTool {
  BrowserDragTool(super.offer);

  @override
  String get name => browserDragToolName;

  @override
  bool get offered => super.offered && offer.trustedInput;

  @override
  String get description => "Press at `from`, move, and release at `to`, in "
      "viewport pixels: for a slider.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {"from": _point, "to": _point},
        "required": ["from", "to"],
      };

  @override
  String get usage => 'The $browserDragToolName tool takes '
      '{"from": {"x": n, "y": n}, "to": {"x": n, "y": n}}.';

  @override
  PageStep? step(Map<String, dynamic> args, BrowserTab tab) {
    final from = PageTool.point(args["from"]), to = PageTool.point(args["to"]);
    if (from == null || to == null) return null;
    return PageStep("(${from.x}, ${from.y}) → (${to.x}, ${to.y})",
        () => tab.drag(from, to),
        acting: "drag from",
        target: () => tab.describeTarget(x: from.x, y: from.y));
  }
}

class BrowserScrollTool extends PageTool {
  BrowserScrollTool(super.offer);

  @override
  String get name => browserScrollToolName;

  @override
  String get description => "Scroll one screen down, or up, and return what "
      "is then in view. The wheel turns over the middle of the viewport and "
      "scrolls whatever is under it. To scroll a panel or frame of its own, "
      "such as a mail's body or a list beside the page, give its `ref`, or a "
      "point inside it by x and y (what a screenshot shows).";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "direction": {
            "type": "string",
            "enum": ["down", "up"],
          },
          "ref": {
            "type": "integer",
            "description": "The number of the element to scroll inside.",
          },
          "x": {"type": "number"},
          "y": {"type": "number"},
        },
      };

  @override
  PageStep step(Map<String, dynamic> args, BrowserTab tab) {
    final up = args["direction"] == "up";
    final at = PageTool.ref(args);
    final x = PageTool.number(args["x"]), y = PageTool.number(args["y"]);
    final label = [
      up ? "up" : "down",
      if (at != null) "in [$at]" else if (x != null && y != null) "at ($x, $y)",
    ].join(" ");
    return PageStep(label, () => tab.scroll(up: up, ref: at, x: x, y: y));
  }
}

class BrowserBackTool extends PageTool {
  BrowserBackTool(super.offer);

  @override
  String get name => browserBackToolName;

  @override
  String get description => "Go back to the previous page.";

  @override
  Map<String, dynamic> get schema =>
      const {"type": "object", "properties": {}};

  @override
  PageStep step(Map<String, dynamic> args, BrowserTab tab) =>
      PageStep("back", tab.back);
}

class BrowserPageTextTool extends PageTool {
  BrowserPageTextTool(super.offer);

  @override
  String get name => browserPageTextToolName;

  @override
  String get runningLabel => "Reading the page";

  @override
  String get description => "The whole page's text and every interactive "
      "element, not just what is in view. Long pages come in chunks: pass "
      "`offset` to read on.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "offset": {"type": "integer"},
        },
      };

  @override
  PageStep step(Map<String, dynamic> args, BrowserTab tab) {
    final offset = PageTool.number(args["offset"])?.toInt() ?? 0;
    return PageStep(offset == 0 ? "page" : "from $offset",
        () => tab.pageText(offset: offset));
  }
}

/// The viewport or one element, shown to the model on the result and to the
/// user in the chat, as a generated image is. Offered only where the model
/// reads images: one that cannot would be paying for pictures it is sent as
/// nothing.
class BrowserScreenshotTool extends BrowserTool {
  BrowserScreenshotTool(super.offer);

  @override
  String get name => browserScreenshotToolName;

  @override
  bool get offered => super.offered && offer.screenshots;

  @override
  String get runningLabel => "Taking a screenshot";

  @override
  String get description => "Take a screenshot of the viewport, or of one "
      "element by number. One image pixel is one viewport pixel, so a point "
      "in it can be clicked by x and y; for an element's screenshot, add the "
      "offset the result gives. Set `last_click` after clicking by x and y to "
      "see where the click landed.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "ref": {"type": "integer"},
          "last_click": {
            "type": "boolean",
            "description": "Mark the last click on this page with a red dot.",
          },
        },
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final ref = intArg(call.argumentsJson, "ref");
    final markClick = boolArg(call.argumentsJson, "last_click");
    final tab = turn.browser!;
    if (BrowserTool.refusedWhileHeld(call, turn) case final refused?) {
      yield* refused;
      return;
    }
    yield toolCalled(call, ref == null ? "viewport" : "[$ref]");
    final BrowserShot shot;
    final ImageEvent saved;
    try {
      shot = await tab.screenshot(ref: ref, markClick: markClick);
      saved = await turn.saved(LlmAttachment(
          filename: "screenshot.png", mimeType: "image/png", bytes: shot.png));
    } catch (e) {
      yield toolFailed(call, "$e");
      return;
    }
    yield saved;
    final click = shot.click;
    final marked = !markClick
        ? ""
        : click == null
            ? " No click to mark: none since the page last loaded or scrolled."
            : " The red dot is the last click, at "
                "(${click.x.round()}, ${click.y.round()}) in the viewport.";
    yield toolOk(
        call,
        BrowserTool.noted(
            turn,
            ref == null
                ? "Screenshot of the viewport attached.$marked"
                : "Screenshot of [$ref] attached. Its top-left corner is at "
                    "(${shot.left.round()}, ${shot.top.round()}) in the "
                    "viewport: add that to a point in it to click there.$marked"));
  }
}

/// The tools that park the turn on the user — a sign-in, the browser handed
/// over — and so ride `ask`, as `present_plan` does: a headless turn has
/// nobody to answer.
abstract class _AskingBrowserTool extends BrowserTool {
  _AskingBrowserTool(super.offer);

  @override
  bool get offered => super.offered && offer.caps.ask;
}

/// Ask the user to fill in a sign-in. What they type goes from the chat's
/// panel to the tab and into the page; the model is told only that it was
/// done, and what the page then shows — passwords and the filled fields
/// redacted.
class BrowserCredentialsPromptTool extends _AskingBrowserTool {
  BrowserCredentialsPromptTool(super.offer);

  @override
  String get name => browserCredentialsPromptToolName;

  @override
  String get runningLabel => "Waiting for you to sign in";

  @override
  String get description => "Ask the user to fill in a sign-in on the current "
      "page. They type into a panel in the app, which types it into the "
      "fields and makes the submit clicks itself; you never see what they "
      "type, and must never ask for a password or code in chat. Waits for "
      "them. For a sign-in over several pages (email, Next, then password), "
      "call once per page.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "reason": {
            "type": "string",
            "description": "Shown to the user, e.g. \"Sign in to GitHub\".",
          },
          "fields": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "ref": {"type": "integer", "description": "The field's number."},
                "label": {"type": "string", "description": "e.g. \"Password\"."},
                "secret": {
                  "type": "boolean",
                  "description": "Obscure what the user types.",
                },
              },
              "required": ["ref", "label"],
            },
          },
          "submit": {
            "type": "array",
            "description": "The clicks that submit the fields, in order: an "
                "element's number, or a point.",
            "items": {
              "type": "object",
              "properties": {
                "ref": {"type": "integer"},
                "x": {"type": "number"},
                "y": {"type": "number"},
              },
            },
          },
        },
        "required": ["reason", "fields"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final tab = turn.browser!;
    final args = decodeArgs(call.argumentsJson) ?? const {};
    final reason = stringArg(call.argumentsJson, "reason");
    final fields = [
      for (final field in (args["fields"] as List? ?? const []))
        if (field is Map && field["ref"] is int && field["label"] is String)
          CredentialField(
            ref: field["ref"] as int,
            label: field["label"] as String,
            secret: field["secret"] == true,
          ),
    ];
    if (reason == null || fields.isEmpty) {
      yield* toolRejected(call, 'The $browserCredentialsPromptToolName tool takes '
          '{"reason": "...", "fields": [{"ref": n, "label": "..."}], '
          '"submit": [{"ref": n}]}.');
      return;
    }
    if (BrowserTool.refusedWhileHeld(call, turn) case final refused?) {
      yield* refused;
      return;
    }
    final submit = [
      for (final click in (args["submit"] as List? ?? const []))
        if (click is Map)
          (
            ref: click["ref"] is int ? click["ref"] as int : null,
            x: (click["x"] as num?)?.toDouble(),
            y: (click["y"] as num?)?.toDouble(),
          ),
    ];
    yield toolCalled(call, reason);
    final String? done;
    try {
      done = await turn.untilStopped(tab.requestCredentials(
          CredentialRequest(reason: reason, fields: fields, submit: submit)));
    } catch (e) {
      yield toolFailed(call, "$e");
      return;
    }
    if (done == null) {
      tab.cancelCredentials();
      yield toolFailed(call, notExecuted);
      return;
    }
    yield toolOk(call, BrowserTool.noted(turn, done));
  }
}

/// Hand the browser to the user: every other browser tool refuses until
/// they give it back, which is what this waits for — an agent told only
/// that the browser refuses tends to give up or end its turn.
class BrowserCredentialsHideTool extends _AskingBrowserTool {
  BrowserCredentialsHideTool(super.offer);

  @override
  String get name => browserCredentialsHideToolName;

  @override
  String get runningLabel => "Waiting for you to hand the browser back";

  @override
  String get description => "Hide the browser from yourself and hand it to "
      "the user, for a sign-in the prompt cannot do: a multi-step login, a "
      "code sent to their phone, a passkey. A button labelled with `reason` "
      "appears in the chat and opens the browser for them. Waits until they "
      "give it back; the page is then as they left it.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "reason": {
            "type": "string",
            "description":
                "The button's label, e.g. \"Please sign in to Google to proceed\".",
          },
        },
        "required": ["reason"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final tab = turn.browser!;
    final reason = stringArg(call.argumentsJson, "reason");
    if (reason == null) {
      yield* toolRejected(call,
          'The $browserCredentialsHideToolName tool takes {"reason": "..."}.');
      return;
    }
    yield toolCalled(call, reason);
    if (tab.hold.value == null) tab.hide(BrowserHold(reason: reason));
    final back = Completer<bool>();
    void given() {
      if (tab.hold.value == null && !back.isCompleted) back.complete(true);
    }

    tab.hold.addListener(given);
    try {
      given();
      if (await turn.untilStopped(back.future) == null) {
        // Stopped: the browser stays the user's until they give it back.
        yield toolFailed(call, notExecuted);
        return;
      }
    } finally {
      tab.hold.removeListener(given);
    }
    yield toolOk(
        call,
        // The giving back is the note's to say.
        BrowserTool.noted(turn, "Read the page again before acting on it: the "
            "user may have moved on from where you left it."));
  }
}

/// Upload through the page's file chooser. Uploads are their own scope
/// ([ToolOffer.uploads]): where the user chooses, the paths are out of the
/// schema altogether and the call opens the chooser and waits on the chat's
/// panel — so a turn with nobody to answer is not offered it; otherwise the
/// agent's own paths go in, past the classifier unless the user said not to
/// ask, described by the files' whole paths, so the classifier sees where
/// they come from, and the element and page they go to.
class BrowserUploadTool extends BrowserTool {
  BrowserUploadTool(super.offer);

  bool get _byUser => offer.uploads == BrowserUploadPolicy.user;

  @override
  String get name => browserUploadToolName;

  @override
  bool get offered =>
      super.offered && offer.trustedInput && (!_byUser || offer.caps.ask);

  @override
  String get runningLabel => "Uploading";

  @override
  String get description => _byUser
      ? "Ask the user to upload a file through the page: give the number of "
          "the upload button or file field. The user chooses the file in the "
          "app, which you cannot do here; the call waits for them, and says "
          "what they chose or that they cancelled."
      : "Upload files from your workspace through the page: give the number "
          "of the upload button or file field, and the files' paths. The "
          "page's file chooser is filled in for you, with no dialog. Only "
          "upload what the task needs.";

  @override
  Map<String, dynamic> get schema => {
        "type": "object",
        "properties": {
          "ref": {
            "type": "integer",
            "description": "The upload button's or file field's number.",
          },
          if (!_byUser)
            "paths": {
              "type": "array",
              "items": {"type": "string"},
              "description": "Files to upload, as the file tools take paths.",
            },
        },
        "required": ["ref", if (!_byUser) "paths"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final tab = turn.browser!;
    if (BrowserTool.refusedWhileHeld(call, turn) case final refused?) {
      yield* refused;
      return;
    }
    final ref = intArg(call.argumentsJson, "ref");
    if (ref == null) {
      yield* toolRejected(call, 'The $browserUploadToolName tool takes {"ref": n'
          '${_byUser ? "" : ', "paths": ["..."]'}}.');
      return;
    }
    if (_byUser) {
      yield toolCalled(call, "[$ref], chosen by the user");
      final String? done;
      try {
        done = await turn.untilStopped(tab.requestUpload(ref));
      } catch (e) {
        yield toolFailed(call, BrowserTool.noted(turn, "$e"));
        return;
      }
      if (done == null) {
        tab.cancelUpload(why: "The turn was stopped.");
        yield toolFailed(call, notExecuted);
        return;
      }
      yield toolOk(call, BrowserTool.noted(turn, done));
      return;
    }
    final paths = [
      for (final path
          in (decodeArgs(call.argumentsJson)?["paths"] as List? ?? const []))
        if (path is String && path.isNotEmpty) path,
    ];
    if (paths.isEmpty) {
      yield* toolRejected(call, 'The $browserUploadToolName tool takes '
          '{"ref": n, "paths": ["..."]}: which files to upload.');
      return;
    }
    final resolved = [for (final path in paths) turn.resolvePath(path)];
    for (var i = 0; i < resolved.length; i++) {
      if (!await turn.fs.file(resolved[i]).exists()) {
        yield* toolRejected(call, "There is no file at ${paths[i]}.");
        return;
      }
    }
    yield toolCalled(call, "[$ref] ${paths.join(", ")}");
    final String target;
    try {
      target = await tab.describeTarget(ref: ref);
    } catch (e) {
      yield toolFailed(call, BrowserTool.noted(turn, "$e"));
      return;
    }
    final described = "upload ${resolved.join(", ")} into $target";
    final outcome = GateOutcome();
    yield* turn.gate.decide(
        BrowserTool.described(call, described),
        browserUploadToolName,
        BrowserTool.attempt(() => tab.upload(ref, resolved)),
        outcome,
        argumentsText: described,
        mode: offer.uploads == BrowserUploadPolicy.allow
            ? ApproveMode.never
            : ApproveMode.auto);
    yield BrowserTool.result(call, turn, outcome);
  }
}
