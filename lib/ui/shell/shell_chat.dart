import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/chat_controller.dart" show TurnDriver;
import "../../app/chat_session.dart";
import "../../app/mirror_controller.dart" show chatViewProvider;
import "../../app/plan.dart";
import "../../app/transcript/transcript.dart";
import "../../domain/plan.dart" show sectionsProgress;
import "../../domain/project.dart";
import "../../domain/room/room_state.dart";
import "../../core/log.dart";
import "../../domain/agent_browser.dart" show BrowserTab;
import "../../providers.dart";
import "../chat/chat_expiry.dart";
import "../chat/chat_settings_page.dart" show openChatSettings;
import "../chat/plan_page.dart" show openPlan;
import "../chat/widgets/browser_strip.dart" show browserOf;
import "../chat/widgets/composer_controller.dart";
import "../chat/widgets/composer_embed.dart" show QuoteEmbed;
import "../selection.dart";
import "../settings/settings_category.dart";
import "shell_answers.dart";
import "shell_composer.dart";
import "shell_conversation.dart";
import "shell_outbox.dart";
import "shell_turn.dart";
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
    _answers.voiceOn.addListener(_turnPass);
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

  _OpenChat? _chat;

  void _open(String? id) {
    if (_chat?.id == id) return;
    _chat?.close();
    _chat = id == null ? null : _OpenChat(this, id);
  }

  void _turnPass() => _chat?.turnPass();

  @override
  void open(ChatBarDestination to) {
    final id = _chat?.id;
    final context = _context();
    if (id == null || !context.mounted) return;
    switch (to) {
      case ChatBarDestination.plan:
        openPlan(context, id);
      case ChatBarDestination.settings:
        openChatSettings(context, id);
    }
  }

  void close() {
    _answers.voiceOn.removeListener(_turnPass);
    _selection.close();
    _chat?.close();
    _chat = null;
  }
}

/// One chat while it is open: its session kept, a surface each, and a
/// reader each that republishes that surface alone.
class _OpenChat {
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
      republish: conversationPass,
    );
    turn = TurnRunner(context: _shell._context, onWithdrawn: composer.restore);
    _conversationReader = TrackingReader(_container, conversationPass);
    _barReader = TrackingReader(_container, barPass);
    _turnReader = TrackingReader(_container, turnPass);
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

  /// The text's ink and a face's outline, by the window's appearance: the
  /// shell's colours rather than a theme's, there being no build to read one.
  ({int ink, Color outline}) _colours(TrackingReader reader) {
    final dark =
        reader.watch(windowSnapshotProvider).dark ??
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    return dark
        ? (ink: 0xFFE3E2E6, outline: const Color(0xFF938F99))
        : (ink: 0xFF1A1C1E, outline: const Color(0xFF79747E));
  }

  void conversationPass() {
    if (_closed) return;
    _conversationReader.pass(() {
      final (:view, :driver) = _state(_conversationReader);
      final chat = view.chat;
      if (chat == null) return;
      // Asked here, there being no page building to ask from while the
      // Flutter view is out of the window.
      if (!_expiryChecked) {
        _expiryChecked = true;
        final context = _shell._context();
        if (context.mounted) checkChatExpiry(context, id, chat.state);
      }
      final (:ink, :outline) = _colours(_conversationReader);
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

  /// Stands down while voice mode is up, whose own turn surface is drawn.
  void turnPass() {
    if (_closed) return;
    if (_answers.voiceOn.value) {
      _answers.turn.release(turn);
      return;
    }
    _turnReader.pass(() {
      final (:view, :driver) = _state(_turnReader);
      if (driver == null || view.chat == null) {
        if (_answers.turn.release(turn)) _outbox.turn(TurnSnapshot());
        return;
      }
      _answers.turn.take(turn);
      _outbox.turn(turn.snapshot(_turnReader, view, driver));
    });
  }

  /// Up where the chat can be written to and nothing stands in its place: a
  /// question the turn waits on, a project still to be set up.
  void composerPass() {
    if (_closed) return;
    _composerReader.pass(() {
      final (:view, :driver) = _state(_composerReader);
      final chat = view.chat;
      final ready =
          chat != null &&
          driver != null &&
          view.roomPhase != RoomPhase.waitingOnYou &&
          (_session.mirrored ||
              _composerReader.watch(setupCompleteProvider(chat.state.project)));
      if (!ready) {
        if (_answers.composer.release(composer)) {
          _outbox.composer(ComposerSnapshot(present: false));
        }
        return;
      }
      final device = _composerReader
          .watch(remoteChatsProvider)
          .where((c) => c.chatId == id)
          .firstOrNull
          ?.deviceId;
      composer.bind(_session.binding(view, driver, device: device));
      _answers.composer.take(composer);
      final (:ink, :outline) = _colours(_composerReader);
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
      final bar = mirrored
          ? (driver == null ? FootBar.offline : FootBar.none)
          : _footReader.watch(setupCompleteProvider(chat.state.project))
          ? FootBar.none
          : FootBar.needsSetup;
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

  void close() {
    _closed = true;
    for (final reader in [
      _conversationReader,
      _barReader,
      _turnReader,
      _composerReader,
      _footReader,
    ]) {
      reader.close();
    }
    if (_answers.transcript.release(conversation)) conversation.clear();
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
