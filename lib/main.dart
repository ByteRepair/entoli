import "dart:async";
import "dart:ui" show AppExitResponse;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "core/config.dart";
import "core/platform/app_icon.dart";
import "core/platform/background_work.dart";
import "core/platform/link_opener.dart";
import "core/platform/platform.dart" as platform;
import "data/local/file_selector_picker.dart";
import "domain/agent_backend.dart";
import "domain/app_restart.dart";
import "domain/prompt_library.dart";
import "providers.dart";
import "ui/app_shell.dart";
import "ui/focus_follows_keyboard.dart";
import "ui/fonts.dart";
import "ui/share/incoming_shares.dart";
import "ui/sidebar/sidebar.dart";
import "ui/theme.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledFontLicences();
  await platform.persist();
  // Built here rather than by the root, so the platform's splash covers the
  // first read of the data directory instead of a blank frame.
  final relaunch = AppRelaunch();
  runApp(AppRoot(session: await AppSession.start(relaunch), relaunch: relaunch));
}

/// Everything the app reads out of the data directory, and the container it is
/// all reached through. One per run of the app — and a second one when a backup
/// is restored, which is what makes the restore land: see [AppRoot].
class AppSession {
  AppSession._(this.container, this._backend, this._sweep);

  final ProviderContainer container;
  final AgentBackend _backend;
  final Timer _sweep;

  static Future<AppSession> start(AppRestart relaunch) async {
    final config = await AppConfig.load(platform.createFileSystem(), await platform.dataDir());
    final store = platform.createChatStore(config);
    final library = await PromptLibrary.from(platform.createPromptSources(config));
    final backend = platform.createBackend(config, library, store);
    final handoff = platform.createFileHandoff(config);
    final container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(store),
        agentBackendProvider.overrideWithValue(backend),
        appConfigProvider.overrideWithValue(config),
        attachmentPickerProvider.overrideWithValue(const FileSelectorPicker()),
        promptLibraryProvider.overrideWithValue(library),
        launcherIconsProvider.overrideWithValue(const LauncherAliases()),
        linkOpenerProvider.overrideWithValue(PlatformLinkOpener(store)),
        backgroundWorkProvider.overrideWithValue(ForegroundService()),
        fileHandoffProvider.overrideWithValue(handoff),
        backupHandoffProvider
            .overrideWithValue(platform.createBackupHandoff(config, handoff)),
        appRestartProvider.overrideWithValue(relaunch),
      ],
    );
    container.read(availableModelsProvider);
    container.read(turnKeepAliveProvider);
    // Sweep expired temporary chats on startup, then every 30 minutes. The
    // timer is in-process and dies with the session: a chat expiring while the
    // app is closed is caught at the next launch. Skips the currently-open
    // chat, which is handled by the on-open prompt.
    await container.read(chatRepositoryProvider).sweepExpired(
          exceptId: container.read(selectedChatIdProvider),
        );
    final sweep = Timer.periodic(const Duration(minutes: 30), (_) {
      container.read(chatRepositoryProvider).sweepExpired(
            exceptId: container.read(selectedChatIdProvider),
          );
    });
    return AppSession._(container, backend, sweep);
  }

  /// A running turn holds a subprocess, so the backend is shut down before the
  /// container that holds it goes.
  Future<void> dispose() async {
    _sweep.cancel();
    await _backend.shutdown();
    container.dispose();
  }
}

/// What the container is handed in place of the root, which does not exist yet
/// when the first session is built. Filled in on the root's first frame, and
/// nothing can ask for a restart before there is a button to press.
class AppRelaunch implements AppRestart {
  Future<void> Function()? onRestart;

  @override
  Future<void> restart() async => onRestart?.call();
}

/// The app, and the ability to build it again. A restart here is a second
/// [AppSession] swapped in and the first thrown away — which is what a restored
/// backup needs and nothing else does. See `domain/app_restart.dart` for why
/// that rather than telling each holder to look afresh.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.session, required this.relaunch});

  final AppSession session;
  final AppRelaunch relaunch;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late AppSession _session = widget.session;

  @override
  void initState() {
    super.initState();
    widget.relaunch.onRestart = _restart;
  }

  Future<void> _restart() async {
    final old = _session;
    // The old session stays on screen while the new one reads the data
    // directory, so what the user sees is one frame rather than a blank app.
    final next = await AppSession.start(widget.relaunch);
    if (!mounted) return next.dispose();
    setState(() => _session = next);
    // After the frame that takes the old tree down: disposing a container the
    // widgets reading it are still mounted against is disposing it under them.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
        // Keyed on the session, so a restart builds the tree again rather than
        // reusing state that was reading the container being thrown away.
        key: ObjectKey(_session),
        container: _session.container,
        child: AgentChatApp(onExit: _session.dispose),
      );
}

class AgentChatApp extends ConsumerStatefulWidget {
  const AgentChatApp({super.key, required this.onExit});

  /// A running turn holds a subprocess; exiting without this leaves it behind.
  final Future<void> Function() onExit;

  @override
  ConsumerState<AgentChatApp> createState() => _AgentChatAppState();
}

class _AgentChatAppState extends ConsumerState<AgentChatApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await widget.onExit();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appSettingsProvider.select((s) => s.appTheme.mode));
    return MaterialApp(
      title: "Entoli",
      theme: entoliTheme(Brightness.light),
      darkTheme: entoliTheme(Brightness.dark),
      themeMode: mode,
      // Both wrapped rather than folded into the shell: what another app shared
      // has to be offered a workspace over whatever is on screen, and a
      // Navigator to push that onto only exists below here; and the keyboard is
      // the app's to answer for, over whichever field had it.
      home: const FocusFollowsKeyboard(child: IncomingShares(child: AppShell())),
    );
  }
}
