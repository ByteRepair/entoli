import "package:flutter/foundation.dart";

import "../domain/file_tools.dart" show guestWorkspacePath;
import "../domain/models.dart";
import "../domain/shell.dart";
import "../domain/wired_skill.dart";
import "completion.dart";

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

/// What a page binds its composer to: the turn it sends into and where it
/// is. One per page, which every frontend's composer is given.
class ComposerBinding {
  const ComposerBinding({
    required this.agentSpeaking,
    required this.onSend,
    required this.onAbort,
    this.onQueue,
    this.steers,
    this.onVoice,
    this.project,
    this.device,
    this.workspace,
    this.workspaceHome,
  });

  /// A participant is speaking: Send becomes Stop.
  final bool agentSpeaking;
  final SendCallback onSend;
  final VoidCallback onAbort;

  /// Send for after the running turn rather than into it; null where there
  /// is no turn to wait on.
  final SendCallback? onQueue;

  /// The room's rule for whether what is typed would steer the running turn.
  final bool Function(String text)? steers;

  /// Opens voice mode; null is none from here.
  final VoidCallback? onVoice;

  /// The project the composer is in, null the default, on [device], null
  /// this one: what the `/` and `@` menus offer.
  final String? project;
  final String? device;

  /// Where this chat's shell starts, and the project workspace its turns
  /// call home; null where the chat does not exist yet.
  final String? workspace;
  final String? workspaceHome;
}

/// The composer as a frontend draws it: the business state, and nothing of
/// how it looks.
class ComposerState {
  const ComposerState({
    required this.value,
    required this.revision,
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

  ComposerState _snapshot() => ComposerState(
    value: _field.textValue,
    revision: _field.revision,
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

  /// [binding]'s turn, as [configure] takes it.
  void bind(ComposerBinding binding) => configure(
    agentSpeaking: binding.agentSpeaking,
    onSend: binding.onSend,
    onQueue: binding.onQueue,
    steers: binding.steers,
    onAbort: binding.onAbort,
    onVoice: binding.onVoice,
  );

  /// The completion menu's token, where the caret is in one and the menu was
  /// not closed on it: the `/` or `@` word being typed.
  CompletionToken? get completion {
    final token = completionTokenIn(_field.text, _field.caret);
    return token == _dismissed ? null : token;
  }

  /// The token the menu was closed on; it stays closed until the caret is in
  /// another.
  CompletionToken? _dismissed;

  /// Close the menu on the token the caret is in.
  void dismissCompletion() {
    _dismissed = completionTokenIn(_field.text, _field.caret);
    _publish();
    notifyListeners();
  }

  /// Take [name] for the open token: the token, up to the caret, becomes the
  /// whole name, and the trailing space makes what follows arguments rather
  /// than more name.
  void acceptCompletion(String name) {
    final token = completion;
    final caret = _field.caret;
    if (token == null || caret == null) return;
    final (:text, caret: at) = completionAccepted(
      _field.text,
      token,
      caret,
      name,
    );
    _field.edit(text, at);
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
        _dismissed = null;
        _openTrigger(CompletionKind.skill);
      case ComposerAction.insertAgent:
        _dismissed = null;
        _openTrigger(CompletionKind.agent);
      case ComposerAction.newGoal:
        _dismissed = null;
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
    // A menu closed on one token opens again on the next.
    if (_dismissed != null &&
        completionTokenIn(text, _field.caret) != _dismissed) {
      _dismissed = null;
    }
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
  return _typedAt(text, triggerPosition(text, caret, kind), kind.trigger);
}

/// [text] with a whole completion typed where [kind]'s trigger goes: the
/// trigger, [name], and the trailing space that makes what follows arguments
/// rather than more name.
({String text, int caret}) completionInserted(
  String text,
  int? caret,
  CompletionKind kind,
  String name,
) =>
    _typedAt(text, triggerPosition(text, caret, kind), "${kind.trigger}$name ");

/// [text] with [token], up to [caret], replaced by [name] as its whole name.
({String text, int caret}) completionAccepted(
  String text,
  CompletionToken token,
  int caret,
  String name,
) {
  final typed = "${token.kind.trigger}$name ";
  return (
    text: text.replaceRange(token.start, caret, typed),
    caret: token.start + typed.length,
  );
}

/// [typed] inserted at [at], spaced off a word it would otherwise run into.
({String text, int caret}) _typedAt(String text, int at, String typed) {
  final spaced = at > 0 && !isCompletionSpace(text.codeUnitAt(at - 1))
      ? " $typed"
      : typed;
  return (text: text.replaceRange(at, at, spaced), caret: at + spaced.length);
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
