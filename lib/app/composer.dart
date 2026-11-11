import "package:flutter/foundation.dart";

import "../domain/file_tools.dart" show guestWorkspacePath;
import "../domain/models.dart";
import "../domain/shell.dart";
import "../domain/wired_skill.dart";

typedef SendCallback = void Function(String text, List<Attachment> attachments);

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

/// What a user can do in the composer. Each frontend places every one of
/// these, or leaves it out, in an exhaustive switch of its own.
enum ComposerAction {
  send,

  /// Hold what is typed for after the running turn rather than steer it.
  queue,
  stop,
  voice,
  attachImage,
  attachFile,
  insertSkill,
  insertAgent,

  /// `/goal ` at the head of the field.
  newGoal,
}

/// The field's text and selection, in UTF-16 code units.
typedef TextValue = ({String text, int start, int end});

/// What the composer needs of the field that holds its text, whichever
/// frontend draws it. [message] is what is sent, [text] what the field holds:
/// the two differ by the embeds, each one character of [text].
abstract interface class ComposerText implements Listenable {
  String get text;
  String get message;
  int get embedCount;

  /// The caret, or null where the field has none.
  int? get caret;

  /// The text and selection now.
  TextValue get textValue;

  /// Bumped whenever the text is set other than by [edited]: a completion
  /// taken, a message restored, the field cleared on send. A frontend whose
  /// field is not this one applies a value only when this moved, so it never
  /// echoes back what was typed — which mid-composition would undo an input
  /// method's marked text.
  int get revision;

  /// What the user typed in a frontend's own field, which bumps nothing.
  void edited(TextValue value);

  /// Replace the whole text and put the caret at [caret].
  void edit(String text, int caret);

  /// Put [said] ahead of what the field holds.
  void prepend(String said);
  void clear();
}

/// The composer as a frontend draws it: the business state, and nothing of
/// how it looks.
class ComposerState {
  const ComposerState({
    required this.value,
    required this.revision,
    required this.focusRequest,
    required this.mode,
    required this.callback,
    required this.speaking,
    required this.voice,
    required this.attachments,
    required this.embeds,
  });

  /// What the field holds, and [revision] counting the times the core set it.
  final TextValue value;
  final int revision;

  /// Bumped when something wants the field focused: Reply on a passage.
  final int focusRequest;
  final ComposerMode mode;

  /// Which callback is typed, not what to call it.
  final WiredCall? callback;

  /// A turn is running: an empty field's button is Stop.
  final bool speaking;

  /// Voice mode can be opened from here.
  final bool voice;
  final List<Attachment> attachments;

  /// How many embeds the field holds.
  final int embeds;
}

/// The composer's business, apart from how it is drawn: what is attached,
/// which [ComposerMode] the text puts it in, whether Send would do anything,
/// whether Queue is on offer, and every [ComposerAction]. The Flutter
/// frontend's `Composer` and the native shell's both run on it.
///
/// It notifies when the mode, the callback, the embeds or the attachments
/// change. [canSend] and [queues] are notifiers of their own, since they flip
/// on keystrokes and only the buttons draw them.
class ComposerModel extends ChangeNotifier {
  ComposerModel(ComposerText field, {required this.pick}) : _field = field {
    field.addListener(_sync);
    _sync();
  }

  /// Everything a frontend draws, as one value: changes on every keystroke.
  ValueListenable<ComposerState> get state => _state;
  late final ValueNotifier<ComposerState> _state = ValueNotifier(_snapshot());

  var _focusRequest = 0;

  /// Ask the frontend for the field's focus: choosing Reply is asking to
  /// write.
  void requestFocus() {
    _focusRequest++;
    _publish();
  }

  ComposerState _snapshot() => ComposerState(
    value: _field.textValue,
    revision: _field.revision,
    focusRequest: _focusRequest,
    mode: _mode,
    callback: _callback,
    speaking: _turn.agentSpeaking,
    voice: _turn.onVoice != null,
    attachments: attachments,
    embeds: _embeds,
  );

  void _publish() => _state.value = _snapshot();

  /// What the user typed in a frontend's own field.
  void edited(TextValue value) => _field.edited(value);

  /// Runs the frontend's picker: the files the user chose.
  final Future<List<Attachment>> Function(AttachmentKind kind) pick;

  ComposerText _field;
  ComposerText get field => _field;
  set field(ComposerText value) {
    if (value == _field) return;
    _field.removeListener(_sync);
    _field = value..addListener(_sync);
    _sync();
    _publish();
  }

  var _turn = (
    agentSpeaking: false,
    onSend: _nothing,
    onQueue: null as SendCallback?,
    steers: null as bool Function(String text)?,
    onAbort: null as VoidCallback?,
    onVoice: null as VoidCallback?,
  );

  static void _nothing(String text, List<Attachment> attachments) {}

  /// What the composer sends to: [agentSpeaking] makes an empty field's
  /// button Stop, and over it [steers] — the room's rule, asked rather than
  /// copied, since only it knows who is speaking — says whether what is typed
  /// would steer, putting [onQueue] on offer beside Send. No [onVoice] is no
  /// voice mode from here.
  void configure({
    required bool agentSpeaking,
    required SendCallback onSend,
    SendCallback? onQueue,
    bool Function(String text)? steers,
    VoidCallback? onAbort,
    VoidCallback? onVoice,
  }) {
    final changed =
        agentSpeaking != _turn.agentSpeaking ||
        (onVoice == null) != (_turn.onVoice == null);
    _turn = (
      agentSpeaking: agentSpeaking,
      onSend: onSend,
      onQueue: onQueue,
      steers: steers,
      onAbort: onAbort,
      onVoice: onVoice,
    );
    if (changed) _changed();
  }

  /// A participant is speaking: an empty field's button is Stop.
  bool get speaking => _turn.agentSpeaking;

  /// Voice mode can be opened from here.
  bool get voice => _turn.onVoice != null;

  final List<Attachment> _attachments = [];
  List<Attachment> get attachments => List.unmodifiable(_attachments);

  ComposerMode _mode = ComposerMode.message;
  ComposerMode get mode => _mode;

  /// The callback typed, which a frontend names; null where there is none.
  WiredCall? _callback;
  WiredCall? get callback => _callback;

  int _embeds = 0;
  int get embeds => _embeds;

  /// Whether Send would do anything.
  final ValueNotifier<bool> canSend = ValueNotifier(false);

  /// Whether what is typed would steer the running turn, so the queue button
  /// is on offer beside Send.
  final ValueNotifier<bool> queues = ValueNotifier(false);

  @override
  void dispose() {
    _field.removeListener(_sync);
    _state.dispose();
    canSend.dispose();
    queues.dispose();
    super.dispose();
  }

  /// Run [action]. Exhaustive, so a new action does not compile until it
  /// does something here.
  Future<void> run(ComposerAction action) async {
    switch (action) {
      case ComposerAction.send:
        submit();
      case ComposerAction.queue:
        submit(queue: true);
      case ComposerAction.stop:
        _turn.onAbort?.call();
      case ComposerAction.voice:
        _turn.onVoice?.call();
      case ComposerAction.attachImage:
        attach(await pick(AttachmentKind.image));
      case ComposerAction.attachFile:
        attach(await pick(AttachmentKind.file));
      case ComposerAction.insertSkill:
        _openTrigger(CompletionKind.skill);
      case ComposerAction.insertAgent:
        _openTrigger(CompletionKind.agent);
      case ComposerAction.newGoal:
        final goal = goalStarted(_field.text);
        _field.edit(goal, goal.length);
    }
  }

  void _openTrigger(CompletionKind kind) {
    final (:text, :caret) = triggerOpened(_field.text, _field.caret, kind);
    _field.edit(text, caret);
  }

  void _sync() {
    _refresh();
    // The field's text rather than the message: an embed is never `!` or a
    // `/skill`, so the answer is the same without writing the message out.
    final text = _field.text;
    final shell = shellBypassCommand(text) != null;
    final wired = shell ? null : wiredSkillFromText(text);
    final mode = shell
        ? ComposerMode.shell
        : wired != null
        ? ComposerMode.callback
        : ComposerMode.message;
    final embeds = _field.embedCount;
    final reshaped = mode != _mode || embeds != _embeds || wired != _callback;
    _mode = mode;
    _callback = wired;
    _embeds = embeds;
    _publish();
    if (reshaped) notifyListeners();
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
        (_turn.steers?.call(_field.message) ?? false);
  }

  /// A file on its own is worth sending, and whitespace on its own is not. An
  /// embed's character is not whitespace, so a quote alone is worth sending.
  bool get worthSending =>
      _field.text.trim().isNotEmpty || _attachments.isNotEmpty;

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
    _field.prepend(text);
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
    send(_field.message.trim(), List.of(_attachments));
    _field.clear();
    _attachments.clear();
    _changed();
  }

  void _changed() {
    _refresh();
    _publish();
    notifyListeners();
  }
}

/// Space, tab, newline — every break a typed message can hold.
bool isCompletionSpace(int codeUnit) =>
    codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A;

/// Where [kind]'s trigger goes: a skill's at the start of the message, since
/// that is the only place `prompt_library.dart`'s `_skillReference` reads one
/// from, and a mention's wherever the caret is.
int triggerPosition(String text, int? caret, CompletionKind kind) =>
    switch (kind) {
      CompletionKind.skill => 0,
      CompletionKind.agent => caret ?? text.length,
    };

/// [text] with [kind]'s trigger typed where it goes, and the caret after it.
/// A skill's already at the start is reused rather than doubled.
({String text, int caret}) triggerOpened(
  String text,
  int? caret,
  CompletionKind kind,
) {
  if (kind == CompletionKind.skill && text.startsWith(kind.trigger)) {
    return (text: text, caret: 1);
  }
  final at = triggerPosition(text, caret, kind);
  final space = at > 0 && !isCompletionSpace(text.codeUnitAt(at - 1))
      ? " "
      : "";
  final typed = "$space${kind.trigger}";
  return (text: text.replaceRange(at, at, typed), caret: at + typed.length);
}

/// [text] as a goal: `/goal ` at its head, so what is already typed becomes
/// the objective. A message already a goal is left as it is.
String goalStarted(String text) {
  const head = "/goal ";
  if (text == "/goal") return head;
  if (text.startsWith(head)) return text;
  return "$head${text.trimLeft()}";
}

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
