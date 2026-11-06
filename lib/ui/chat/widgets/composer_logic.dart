import "package:flutter/foundation.dart";

import "../../../domain/file_tools.dart" show guestWorkspacePath;
import "../../../domain/goal.dart";
import "../../../domain/models.dart";
import "../../../domain/shell.dart";
import "../../../domain/wired_skill.dart";
import "composer_controller.dart";
import "composer_embed.dart";

typedef SendCallback = void Function(String text, List<Attachment> attachments);

/// What a page asks of whichever composer it has, the Flutter one or the
/// native shell's: a steer taken back put back, and a passage replied to.
abstract interface class ComposerHandle {
  void restore(Draft said);
  void embed(ComposerEmbed embed);
}

/// What the field is about to do with what is typed in it.
enum ComposerMode {
  /// Say it.
  message,

  /// Run it on the machine: a `!` command. Drawn rather than only obeyed,
  /// since `!` sends the message somewhere else entirely and nothing else in
  /// the composer would say so before Send is pressed.
  shell,

  /// Run a callback rather than ask for anything said: a `/skill` flagged
  /// `invocation: callback`, said the same way from the keystroke that
  /// decides it.
  callback,
}

/// What each composer says about its [ComposerMode], in its own dress.
extension ComposerModeWords on ComposerMode {
  /// The field's hint, where the mode has one of its own; a message's is the
  /// composer's. A callback has none: the field holding one is never empty.
  String? get hint => switch (this) {
    ComposerMode.shell => "Shell command",
    ComposerMode.callback || ComposerMode.message => null,
  };

  /// What the send button does, said as its tooltip or label. [queues] is
  /// [ComposerLogic.queues]: what is typed would steer the running turn.
  /// [callback] is [ComposerLogic.callbackLabel], which names the callback
  /// typed — there is more than one.
  String sendLabel({required bool queues, String? callback}) => switch (this) {
    ComposerMode.shell => "Run",
    ComposerMode.callback => callback ?? "Run",
    ComposerMode.message => queues ? "Send now, read at its next step" : "Send",
  };
}

/// What sending the callback [wired] does, as the send button says it.
String callbackSendLabel(WiredCall wired) => switch (wired.skill) {
  WiredSkill.compact => "Compact",
  WiredSkill.goal => switch (goalCommandOf(wired.arguments)) {
    GoalSet() => "Set goal",
    GoalResume() => "Resume goal",
    GoalPause() => "Pause goal",
    GoalClear() => "Clear goal",
    GoalShow() => "Show goal",
  },
};

/// Where a `!` command runs before the shell has said: [workspace], in the
/// guest's own words where commands run in one under [guestRoot]. [home] is
/// the project workspace beside it, what the guest path is worded from.
String workingDirectoryFallback({
  required String workspace,
  required String? guestRoot,
  required String? home,
}) => guestRoot != null && home != null
    ? guestWorkspacePath(guestRoot, home, workspace)
    : workspace;

/// What a composer decides, apart from how it is drawn: what is attached,
/// which [ComposerMode] the text puts it in, whether Send would do anything,
/// whether Queue is on offer, and sending. The Material `Composer` draws it,
/// and so does the native shell's composer on iOS and macOS, so there is one
/// copy of the rules.
///
/// It notifies when what changes the composer's shape changes — the mode, the
/// embeds, the attachments. [canSend] and [queues] are notifiers of their own,
/// since they flip on keystrokes and only the buttons draw them.
class ComposerLogic extends ChangeNotifier {
  ComposerLogic(ComposerController controller) : _controller = controller {
    controller.addListener(_sync);
    _sync();
  }

  ComposerController _controller;

  /// The field, and the quotes and other embeds in it. What is sent is its
  /// `message`, never its `text`.
  ComposerController get controller => _controller;
  set controller(ComposerController value) {
    if (value == _controller) return;
    _controller.removeListener(_sync);
    _controller = value..addListener(_sync);
    _sync();
  }

  var _turn = (
    agentSpeaking: false,
    onSend: _nothing,
    onQueue: null as SendCallback?,
    steers: null as bool Function(String text)?,
  );

  static void _nothing(String text, List<Attachment> attachments) {}

  /// What the composer sends to: [agentSpeaking] makes an empty field's
  /// button Stop, and over it [steers] — the room's rule, asked rather than
  /// copied, since only it knows who is speaking — says whether what is typed
  /// would steer, putting [onQueue] on offer beside Send.
  void configure({
    required bool agentSpeaking,
    required SendCallback onSend,
    SendCallback? onQueue,
    bool Function(String text)? steers,
  }) {
    final changed = agentSpeaking != _turn.agentSpeaking;
    _turn = (
      agentSpeaking: agentSpeaking,
      onSend: onSend,
      onQueue: onQueue,
      steers: steers,
    );
    if (changed) _refresh();
  }

  final List<Attachment> _attachments = [];
  List<Attachment> get attachments => List.unmodifiable(_attachments);

  ComposerMode _mode = ComposerMode.message;
  ComposerMode get mode => _mode;

  /// What the callback typed does, for the send button; null where the
  /// field holds none.
  String? _callbackLabel;
  String? get callbackLabel => _callbackLabel;

  /// How many embeds the field holds: each is taller than a line, so a field
  /// lets itself grow by them rather than scroll them away.
  int _embeds = 0;
  int get embeds => _embeds;

  /// How many lines the field grows to before it scrolls: two more per embed,
  /// up to four of them.
  int get maxLines => 6 + 2 * _embeds.clamp(0, 4);

  /// Whether Send would do anything.
  final ValueNotifier<bool> canSend = ValueNotifier(false);

  /// Whether what is typed would steer the running turn, so the queue button
  /// is on offer beside Send.
  final ValueNotifier<bool> queues = ValueNotifier(false);

  @override
  void dispose() {
    _controller.removeListener(_sync);
    canSend.dispose();
    queues.dispose();
    super.dispose();
  }

  void _sync() {
    _refresh();
    // The field's text rather than the message: an embed is never `!` or a
    // `/skill`, so the answer is the same without writing the message out.
    final text = _controller.text;
    final wired = shellBypassCommand(text) != null
        ? null
        : wiredSkillFromText(text);
    final mode = shellBypassCommand(text) != null
        ? ComposerMode.shell
        : wired != null
        ? ComposerMode.callback
        : ComposerMode.message;
    final label = wired == null ? null : callbackSendLabel(wired);
    final embeds = _controller.embeds.length;
    if (mode == _mode && embeds == _embeds && label == _callbackLabel) return;
    _mode = mode;
    _callbackLabel = label;
    _embeds = embeds;
    notifyListeners();
  }

  void _refresh() {
    final worth = worthSending;
    canSend.value = worth;
    // Only asked with something typed: the room composes a message to answer,
    // and a streaming reply rebuilds the page every frame.
    queues.value =
        worth &&
        _turn.agentSpeaking &&
        _turn.onQueue != null &&
        (_turn.steers?.call(_controller.message) ?? false);
  }

  /// A file on its own is worth sending, and whitespace on its own is not. An
  /// embed's character is not whitespace, so a quote alone is worth sending.
  bool get worthSending =>
      _controller.text.trim().isNotEmpty || _attachments.isNotEmpty;

  void attach(List<Attachment> files) {
    if (files.isEmpty) return;
    _attachments.addAll(files);
    _changed();
  }

  void unattach(int index) {
    if (index < 0 || index >= _attachments.length) return;
    _attachments.removeAt(index);
    _changed();
  }

  /// Put back a message that was sent and taken back, ahead of whatever has
  /// been typed or attached since.
  void restore(Draft said) {
    final (:text, :attachments) = said;
    _controller.prepend(text);
    _attachments.insertAll(0, attachments);
    _changed();
  }

  /// Send what is composed, or with [queue] hold it for after the running
  /// turn where [queues] says that is on offer; then clear both. Nothing where
  /// nothing is worth sending, since a key reaches here without passing the
  /// button.
  void submit({bool queue = false}) {
    if (!worthSending) return;
    final send = queue && queues.value ? _turn.onQueue! : _turn.onSend;
    send(_controller.message.trim(), List.of(_attachments));
    _controller.clear();
    _attachments.clear();
    _changed();
  }

  void _changed() {
    _refresh();
    notifyListeners();
  }
}
