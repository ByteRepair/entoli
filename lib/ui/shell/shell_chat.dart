import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/chat_controller.dart" show TurnDriver;
import "../../app/chat_session.dart";
import "../../app/composer.dart";
import "../../app/mirror_controller.dart" show chatViewProvider;
import "../../app/new_chat_session.dart";
import "../../domain/chat_meta.dart";
import "../../app/plan.dart";
import "../../app/transcript/chapters.dart";
import "../../app/transcript/transcript.dart";
import "../../domain/plan.dart" show sectionsProgress;
import "../../domain/project.dart";
import "../../domain/room/room_state.dart";
import "../../core/log.dart";
import "../../domain/agent_browser.dart" show BrowserTab;
import "../../providers.dart";
import "../chat/chat_expiry.dart";
import "../chat/chat_settings_page.dart"
    show openChatSettings, openNewChatSettings;
import "../chat/plan_page.dart" show openPlan;
import "../chat/widgets/browser_strip.dart" show browserOf;
import "../chat/widgets/composer_controller.dart";
import "../chat/widgets/composer_embed.dart" show QuoteEmbed;
import "../selection.dart";
import "../settings/settings_category.dart";
import "markdown_encoder.dart" show inkOf;
import "shell_answers.dart";
import "shell_composer.dart";
import "shell_conversation.dart";
import "shell_new_chat.dart";
import "shell_outbox.dart";
import "shell_turn.dart";
import "shell_voice.dart";
import "shell_browser.dart";
import "shell_window.dart" show windowSnapshotProvider;
import "tracking_reader.dart";

/// The open chat as the native shell draws it — its conversation, its title
/// bar, its turn surface and its composer — published from the app's state
/// rather than from a widget's build, so it is sent while the Flutter view
/// is out of the window and no frame comes. Held by `ShellBridge`, following
/// the selected chat; each surface is a pass over a [TrackingReader] that
/// runs again when anything it read changes. Its intents are answered here,
/// pages opened over [_context], the bridge's.
class ShellChat implements ChatBarIntents {
  ShellChat(this._container, this._context) {
    _selection = _container.listen<String?>(
      selectedChatIdProvider,
      (_, id) => _open(id),
      fireImmediately: true,
    );
  }

  final ProviderContainer _container;
  final BuildContext Function() _context;

  late final ShellOutbox _outbox = _container.read(shellOutboxProvider);
  late final ShellAnswers _answers = _container.read(shellAnswersProvider);
  late final ProviderSubscription<String?> _selection;

  _Screen? _screen;

  /// Voice mode, while it is up.
  ShellVoiceSession? _voice;

  /// The browser's view, while it is up.
  BrowserWindowSession? _browser;

  /// Shows [tab] natively: `NativeSurfaces.openBrowser` under the shell.
  void openBrowser(
    BrowserTab tab, {
    required Future<void> Function() onQuit,
    required bool window,
  }) {
    _browser?.dispose();
    _browser = BrowserWindowSession(
      tab: tab,
      outbox: _outbox,
      answers: _answers,
      onQuit: onQuit,
      windowed: window,
      onClose: closeBrowser,
    );
  }

  void closeBrowser() {
    _browser?.dispose();
    _browser = null;
  }

  /// Opens voice mode over [chatId], or over no chat yet to be made under
  /// [meta]: `NativeSurfaces.openVoice` under the shell.
  void openVoice(String? chatId, ChatMeta? meta) {
    _voice?.close();
    _voice = ShellVoiceSession(
      _container,
      chatId: chatId,
      meta: meta,
      context: _context,
      onDone: closeVoice,
    );
  }

  void closeVoice() {
    _voice?.close();
    _voice = null;
  }

  void _open(String? id) {
    if (_screen != null && _screen!.id == id) return;
    // The view is of the chat's own tab.
    closeBrowser();
    // From one chat to another the conversation is handed over rather than
    // taken down, so it never leaves the screen between them.
    _screen?.close(handingOver: id != null);
    _screen = id == null ? _NewChat(this) : _OpenChat(this, id);
  }

  @override
  void open(ChatBarDestination to) => _screen?.openBar(to);

  void close() {
    _selection.close();
    closeVoice();
    closeBrowser();
    _screen?.close();
    _screen = null;
  }
}

/// What `ShellChat` draws now: an open chat, or the new-chat screen.
sealed class _Screen {
  String? get id;
  void turnPass();
  void openBar(ChatBarDestination to);

  /// [handingOver] is a chat opening next, which takes the conversation.
  void close({bool handingOver = false});
}

/// One chat while it is open: its session kept, a surface each, and a
/// reader each that republishes that surface alone.
final class _OpenChat implements _Screen {
  _OpenChat(this._shell, this.id) {
    _keep = _container.listen(chatSessionProvider(id), (_, _) {});
    final session = _keep.read();
    _session = session;
    composer = ComposerSurface(
      outbox: _shell._outbox,
      model: session.composer,
      controller: session.text as ComposerController,
      clipboardFiles: () => _container.read(clipboardFilesProvider).read(),
    );
    conversation = ConversationSurface(
      context: _shell._context,
      onReply: (quote) => composer.embed(QuoteEmbed(quote)),
      republish: () => _conversationReader.refresh(),
    );
    turn = TurnRunner(
      context: _shell._context,
      onWithdrawn: composer.restore,
      openDetail: (detail) => conversation.openRun(
        detail.activity,
        detail.run,
        source: detail.source,
      ),
    );
    _conversationReader = TrackingReader(_container, conversationPass);
    _barReader = TrackingReader(_container, barPass);
    _turnReader = TrackingReader(_container, turnPass);
    _answers.turn.addListener(_turnReader.refresh);
    _composerReader = TrackingReader(_container, composerPass)
      ..listen(composer.shape);
    foot = _FootRunner(_shell._context);
    _footReader = TrackingReader(_container, footPass);
    _answers.transcript.take(conversation);
    _answers.chatBar.take(_shell);
    _answers.foot.take(foot);
    conversationPass();
    barPass();
    turnPass();
    composerPass();
    footPass();
  }

  final ShellChat _shell;
  @override
  final String id;

  ProviderContainer get _container => _shell._container;
  ShellOutbox get _outbox => _shell._outbox;
  ShellAnswers get _answers => _shell._answers;

  late final ProviderSubscription<ChatSession> _keep;
  late final ChatSession _session;
  late final ComposerSurface composer;
  late final ConversationSurface conversation;
  late final TurnRunner turn;
  late final TrackingReader _conversationReader;
  late final TrackingReader _barReader;
  late final TrackingReader _turnReader;
  late final TrackingReader _composerReader;
  late final _FootRunner foot;
  late final TrackingReader _footReader;

  bool _closed = false;
  bool _expiryChecked = false;

  /// The chat's view and what drives its turns, read through [reader] so a
  /// change to either — a mirror going offline — runs the pass again.
  ({ChatViewState view, TurnDriver? driver}) _state(TrackingReader reader) {
    final view = reader.watch(chatViewProvider(id));
    reader.watch(isMirroredChatProvider(id));
    reader.watch(remoteChatsProvider);
    return (view: view, driver: _session.driver);
  }

  void conversationPass() {
    if (_closed) return;
    _conversationReader.pass(() {
      final (:view, :driver) = _state(_conversationReader);
      final chat = view.chat;
      if (chat == null) {
        if (_answers.transcript.owner == conversation) {
          conversation.loading(id);
        }
        return;
      }
      // Asked here, there being no page building to ask from while the
      // Flutter view is out of the window.
      if (!_expiryChecked) {
        _expiryChecked = true;
        final context = _shell._context();
        if (context.mounted) checkChatExpiry(context, id, chat.state);
      }
      final (:ink, :outline) = _shellColours(_conversationReader);
      conversation.publish(
        _conversationReader,
        chatId: id,
        transcript: Transcript.of(
          id,
          chat,
          compactFailure: view.compactFailure,
        ),
        view: view,
        source: _session.source,
        driver: driver,
        ink: ink,
        outline: outline,
        chapters: chaptersOf(chat),
      );
    });
  }

  void barPass() {
    if (_closed) return;
    _barReader.pass(() {
      final view = _barReader.watch(chatViewProvider(id));
      final state = view.chat?.state;
      if (state == null) return;
      final plan = _barReader.watch(planProvider(id)).value;
      final progress = plan == null ? null : sectionsProgress(plan);
      _outbox.chatBar(
        ChatBarSnapshot(
          title: state.title,
          project: state.project == null ? null : projectLabel(state.project),
          pinned: state.pinned,
          expiresAt: state.tempTtlExpiresAt?.millisecondsSinceEpoch,
          running: view.isRunning,
          planDone: progress?.$1,
          planTotal: progress?.$2,
        ),
      );
    });
  }

  @override
  void openBar(ChatBarDestination to) {
    final context = _shell._context();
    if (!context.mounted) return;
    switch (to) {
      case ChatBarDestination.plan:
        openPlan(context, id);
      case ChatBarDestination.settings:
        openChatSettings(context, id);
    }
  }

  /// Sends nothing while covered — voice mode's turn surface is drawn over
  /// it — and again once the cover goes.
  @override
  void turnPass() {
    if (_closed) return;
    _turnReader.pass(() {
      final (:view, :driver) = _state(_turnReader);
      if (driver == null || view.chat == null) {
        if (_answers.turn.release(turn)) _outbox.turn(TurnSnapshot());
        return;
      }
      if (!_answers.turn.take(turn)) return;
      _outbox.turn(turn.snapshot(_turnReader, view, driver));
    });
  }

  /// Up where the session's slot is the composer.
  void composerPass() {
    if (_closed) return;
    _composerReader.pass(() {
      final (:view, :driver) = _state(_composerReader);
      final device = _composerReader
          .watch(remoteChatsProvider)
          .where((c) => c.chatId == id)
          .firstOrNull
          ?.deviceId;
      final slot = _session.slot(_composerReader, view, driver, device: device);
      if (slot is! ComposerReady) {
        if (_answers.composer.release(composer)) {
          _outbox.composer(ComposerSnapshot(present: false));
        }
        return;
      }
      composer.bind(slot.binding);
      _answers.composer.take(composer);
      final (:ink, :outline) = _shellColours(_composerReader);
      _outbox.composer(
        composer.snapshot(
          _composerReader,
          pixelRatio: WidgetsBinding
              .instance
              .platformDispatcher
              .implicitView!
              .devicePixelRatio,
          outline: outline,
        ),
      );
    });
  }

  /// The chat's edges: the device a mirror lives on, what stands in the
  /// composer's place, and what the browser waits on the user for.
  void footPass() {
    if (_closed) return;
    _footReader.pass(() {
      final (:view, :driver) = _state(_footReader);
      final chat = view.chat;
      if (chat == null) return;
      final remote = _footReader
          .watch(remoteChatsProvider)
          .where((c) => c.chatId == id)
          .firstOrNull;
      final mirrored = _session.mirrored;
      final bar = _barOf(_session.slot(_footReader, view, driver));
      final browser = browserOf(
        _footReader.watch(agentBrowserProvider),
        mirrored,
        id,
      );
      foot.browser = browser;
      final tab = browser?.tab;
      if (tab != null) {
        _footReader
          ..hear(tab.hold)
          ..hear(tab.credentialRequest)
          ..hear(tab.uploadRequest);
      }
      final upload = tab?.uploadRequest.value;
      final credentials = tab?.credentialRequest.value;
      _outbox.foot(
        ChatFootSnapshot(
          device: mirrored ? remote?.deviceName ?? "the home device" : null,
          deviceOffline: mirrored && !(remote?.online ?? false),
          bar: bar,
          hold: tab?.hold.value?.reason,
          upload: upload == null
              ? null
              : UploadPrompt(
                  host: Uri.tryParse(upload.url)?.host ?? "",
                  multiple: upload.multiple,
                ),
          credentials: credentials == null
              ? null
              : CredentialPrompt(
                  reason: credentials.reason,
                  fields: [
                    for (final f in credentials.fields)
                      CredentialField(label: f.label, secret: f.secret),
                  ],
                ),
        ),
      );
    });
  }

  @override
  void close({bool handingOver = false}) {
    _closed = true;
    _answers.turn.removeListener(_turnReader.refresh);
    for (final reader in [
      _conversationReader,
      _barReader,
      _turnReader,
      _composerReader,
      _footReader,
    ]) {
      reader.close();
    }
    if (_answers.transcript.release(conversation) && !handingOver) {
      conversation.clear();
    }
    if (_answers.composer.release(composer)) {
      _outbox.composer(ComposerSnapshot(present: false));
    }
    if (_answers.turn.release(turn)) _outbox.turn(TurnSnapshot());
    _answers.chatBar.release(_shell);
    if (_answers.foot.release(foot)) _outbox.foot(ChatFootSnapshot());
    composer.dispose();
    _keep.close();
  }
}

/// What the user does at the open chat's edges, run over the bridge's
/// context: Settings for a project's setup, the browser's page and what it
/// waits on.
class _FootRunner implements ChatFootIntents {
  _FootRunner(this._context);

  final BuildContext Function() _context;

  /// The chat's browser tab and its live view, as the last pass found it.
  ({BrowserTab tab, void Function(BuildContext context) open})? browser;

  @override
  void openSetup() {
    final context = _context();
    if (context.mounted) {
      openSettings(context, category: SettingsCategory.byteRepair, focus: true);
    }
  }

  @override
  void watchPage() {
    final context = _context();
    if (context.mounted) browser?.open(context);
  }

  @override
  void cancelUpload() => browser?.tab.cancelUpload();

  @override
  void upload(List<String> paths) {
    final tab = browser?.tab;
    if (tab == null || paths.isEmpty) return;
    tab.submitUpload(paths).catchError((Object e) {
      logFailure("browser", "files could not be given to the page", e);
    });
  }

  @override
  void submitCredentials(List<String> values) {
    browser?.tab.submitCredentials(values).catchError((Object e) {
      logFailure("browser", "a sign-in could not be typed in", e);
    });
  }

  @override
  void declineCredentials() => browser?.tab.declineCredentials();
}

/// The new-chat screen while nothing is selected: its body, its bar, its
/// composer and what stands in the composer's place, from the
/// [NewChatSession] the Flutter page shares.
final class _NewChat implements _Screen {
  _NewChat(this._shell) {
    _keep = _container.listen(newChatSessionProvider, (_, _) {});
    final session = _session = _keep.read();
    final controller = session.text as ComposerController;
    composer = ComposerSurface(
      outbox: _outbox,
      model: session.composer,
      controller: controller,
      clipboardFiles: () => _container.read(clipboardFilesProvider).read(),
    );
    screen = NewChatRunner(_container, controller: controller);
    _screenReader = TrackingReader(_container, screenPass)
      ..listen(session.starting);
    _barReader = TrackingReader(_container, barPass)..listen(session.meta);
    _composerReader = TrackingReader(_container, composerPass)
      ..listen(composer.shape)
      ..listen(session.starting);
    _footReader = TrackingReader(_container, footPass);
    _answers.newChat.take(screen);
    _answers.chatBar.take(_shell);
    _answers.foot.take(_foot);
    // The open chat's, gone with it.
    _shell._outbox.turn(TurnSnapshot());
    screenPass();
    barPass();
    composerPass();
    footPass();
  }

  final ShellChat _shell;
  @override
  String? get id => null;

  ProviderContainer get _container => _shell._container;
  ShellOutbox get _outbox => _shell._outbox;
  ShellAnswers get _answers => _shell._answers;

  late final ProviderSubscription<NewChatSession> _keep;
  late final NewChatSession _session;
  late final ComposerSurface composer;
  late final NewChatRunner screen;
  late final _foot = _FootRunner(_shell._context);
  late final TrackingReader _screenReader;
  late final TrackingReader _barReader;
  late final TrackingReader _composerReader;
  late final TrackingReader _footReader;
  bool _closed = false;

  ProjectRef _at(TrackingReader reader) =>
      reader.watch(selectedProjectProvider);

  void screenPass() {
    if (_closed) return;
    _screenReader.pass(() {
      _outbox.newChat(
        screen.snapshot(
          _screenReader,
          _at(_screenReader),
          starting: _session.starting.value,
        ),
      );
    });
  }

  void barPass() {
    if (_closed) return;
    _barReader.pass(() {
      final at = _at(_barReader);
      _outbox.chatBar(
        ChatBarSnapshot(
          draft: true,
          project: at.project == null ? null : projectLabel(at.project),
          settings: at.device == null,
        ),
      );
    });
  }

  void composerPass() {
    if (_closed) return;
    _composerReader.pass(() {
      final slot = _session.slot(_composerReader, _at(_composerReader));
      if (slot is! ComposerReady) {
        if (_answers.composer.release(composer)) {
          _outbox.composer(ComposerSnapshot(present: false));
        }
        return;
      }
      composer.bind(slot.binding);
      _answers.composer.take(composer);
      final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
      _outbox.composer(
        composer.snapshot(
          _composerReader,
          pixelRatio: view.devicePixelRatio,
          outline: _shellColours(_composerReader).outline,
        ),
      );
    });
  }

  /// What stands in the composer's place: a project to set up, a paired
  /// device's project gone frozen.
  void footPass() {
    if (_closed) return;
    _footReader.pass(() {
      _outbox.foot(
        ChatFootSnapshot(
          bar: _barOf(_session.slot(_footReader, _at(_footReader))),
        ),
      );
    });
  }

  @override
  void turnPass() {}

  /// The bar's settings: what the chat this screen makes will run under.
  @override
  void openBar(ChatBarDestination to) {
    final context = _shell._context();
    if (to != ChatBarDestination.settings || !context.mounted) return;
    final session = _session;
    openNewChatSettings(
      context,
      initial: session.meta.value,
      project: _container.read(selectedProjectProvider).project,
      onSave: (meta) {
        if (!_closed) session.meta.value = meta;
      },
    );
  }

  @override
  void close({bool handingOver = false}) {
    _closed = true;
    for (final reader in [
      _screenReader,
      _barReader,
      _composerReader,
      _footReader,
    ]) {
      reader.close();
    }
    if (_answers.newChat.release(screen)) {
      _outbox.newChat(NewChatSnapshot(present: false));
    }
    if (_answers.composer.release(composer)) {
      _outbox.composer(ComposerSnapshot(present: false));
    }
    _answers.chatBar.release(_shell);
    if (_answers.foot.release(_foot)) _outbox.foot(ChatFootSnapshot());
    composer.dispose();
    _keep.close();
  }
}

/// What the foot draws in the composer's place for [slot].
FootBar _barOf(ComposerSlot slot) => switch (slot) {
  ComposerNeedsSetup() => FootBar.needsSetup,
  ComposerViewOnly() => FootBar.offline,
  ComposerReady() || ComposerAnswering() || ComposerStarting() => FootBar.none,
};

/// The text's ink and a face's outline, by the window's appearance: the
/// shell's colours rather than a theme's, there being no build to read one.
({int ink, Color outline}) _shellColours(TrackingReader reader) {
  final dark =
      reader.watch(windowSnapshotProvider).dark ??
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark;
  return (
    ink: inkOf(dark: dark),
    outline: dark ? const Color(0xFF938F99) : const Color(0xFF79747E),
  );
}
