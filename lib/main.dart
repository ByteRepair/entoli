import "dart:async";
import "dart:ui" show AppExitResponse;

import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "core/config.dart";
import "core/platform/app_icon.dart";
import "core/platform/background_work.dart";
import "core/platform/platform.dart" as platform;
import "core/platform/system_palette.dart";
import "data/local/file_reminder_store.dart";
import "data/local/file_selector_picker.dart";
import "data/sync/file_devices.dart";
import "data/sync/sync_hub.dart";
import "domain/app_restart.dart";
import "domain/prompt_library.dart";
import "domain/sync/identity.dart";
import "domain/voice_model.dart" show nativeRecognition, nativeSpeech;
import "providers.dart";
import "ui/chat/remote_turns.dart";
import "ui/app_shell.dart";
import "ui/chat/chat_controller.dart";
import "ui/assistant/incoming_assistant.dart";
import "ui/focus_follows_keyboard.dart";
import "ui/fonts.dart";
import "ui/link_opener.dart";
import "ui/share/incoming_shares.dart";
import "ui/reminders/incoming_open.dart";
import "ui/sidebar/sidebar.dart";
import "ui/theme.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledFontLicences();
  platform.registerVoiceLicences();
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
  AppSession._(this.container, this._sweep);

  final ProviderContainer container;
  final Timer _sweep;

  static Future<AppSession> start(AppRestart relaunch) async {
    // Started here and awaited below: on Android it is a channel round trip
    // that nothing between depends on.
    final cacheDir = platform.cacheDir();
    // Started with it and awaited below for the same reason: laying the tools
    // out is a channel round trip and a handful of symlinks, and nothing
    // between depends on either.
    final tools = cacheDir.then(platform.installBundledTools);
    // A third round trip on the same channel, and the only thing that decides
    // which rootfs a download fetches.
    final abi = platform.deviceAbi();
    // Started with them and awaited below: an asset read off a disk, or a fetch
    // in a browser, and nothing between wants it.
    final version = platform.appVersion();
    final accent = systemAccent();
    final config = await AppConfig.load(platform.createFileSystem(), await platform.dataDir());
    final store = platform.createChatStore(config);
    final library = await PromptLibrary.from(platform.createPromptSources(config));
    final handoff = platform.createFileHandoff(config);
    final cache = await cacheDir;
    final rootfs = platform.createRootfsStore(cache);
    final localModels = platform.createLocalModelStore(cache);
    // Started here and awaited below, the way the three above are: it is a
    // channel round trip and a `stat`, and laying the tools out is another —
    // neither needs the other's answer. The backend does need this one, since a
    // provider list composed without it would leave the on-device model out of
    // the first turn after a launch.
    final localLlm = platform.createLocalLlm(localModels, cache);
    final toolset = await tools;
    final server = await localLlm;
    // Beside the pool, so the two agree on where the server's slot dumps go.
    final kvCache = platform.createLocalKvCache(cache, server);
    final backend = platform.createBackend(config, library, store,
        tools: toolset, rootfs: rootfs, abi: await abi, localLlm: server, kvCache: kvCache);
    // One instance, shared: the prefill's notification and every other
    // foreground hold go through the same service.
    final foreground = ForegroundService();
    final prefill = platform.createLocalPrefill(backend, server, foreground, config,
        kvCache: kvCache);
    final voiceModels = platform.createVoiceModelStore(cache);
    final voice = platform.createVoice(voiceModels, cache);
    // Both started before either is awaited: one is a disk scan and the other
    // a channel round trip, and neither needs the other's answer.
    final scan = voiceModels.installed();
    final engines = await voice.systemEngines();
    // A sentinel the device can honour is usable on exactly the same terms as
    // a downloaded model, so it goes in the same set — see [InstalledVoiceModels].
    final system = {
      if (engines.recognition) nativeRecognition.id,
      if (engines.speech) nativeSpeech.id,
    };
    final installed = {...await scan, ...system};
    // Read here for the reason the voice models are: the Terminal and On-device
    // pages' rows and the pickers above them are drawn from it, and a scan
    // started when the page opens would draw every row as "not installed"
    // first. Both at once — they are two directories and neither needs the
    // other.
    final scans = await Future.wait([rootfs.installed(), localModels.installed()]);
    final reminders = await FileReminderStore(config).load();
    // Sync: identity from the keyring (or file fallback), registry on disk.
    // The hub reads settings from the container; the closure below defers
    // that read until after the container exists — the same pattern the
    // repository uses with `() => ref.read(appSettingsProvider)`.
    final secretStore = platform.createSecretStore(config);
    final identity = await SyncIdentity.load(secretStore);
    final registry = FileDeviceRegistry(config, secretStore);
    // Assigned two statements down, and read only from a running app — the
    // hub has to exist before the container that overrides its provider.
    late final ProviderContainer settingsHome;
    final syncHub = SyncHub(
      identity: identity,
      registry: registry,
      settings: () => settingsHome.read(appSettingsProvider),
      lanSignaling: platform.createLanSignaling,
      hostname: platform.deviceHostname(),
    );
    final container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(store),
        agentBackendProvider.overrideWithValue(backend),
        appConfigProvider.overrideWithValue(config),
        attachmentPickerProvider.overrideWithValue(const FileSelectorPicker()),
        promptLibraryProvider.overrideWithValue(library),
        launcherIconsProvider.overrideWithValue(const LauncherAliases()),
        systemAccentProvider.overrideWithValue(await accent),
        linkOpenerProvider.overrideWithValue(PlatformLinkOpener(store)),
        backgroundWorkProvider.overrideWithValue(foreground),
        fileHandoffProvider.overrideWithValue(handoff),
        assistantLaunchProvider.overrideWithValue(platform.createAssistantLaunch()),
        reminderAlarmsProvider.overrideWithValue(platform.createReminderAlarms()),
        remindersProvider.overrideWith(() => Reminders(reminders)),
        backupHandoffProvider
            .overrideWithValue(platform.createBackupHandoff(config, handoff)),
        appRestartProvider.overrideWithValue(relaunch),
        voiceModelStoreProvider.overrideWithValue(voiceModels),
        voiceProvider.overrideWithValue(voice),
        installedVoiceModelsProvider
            .overrideWith(() => InstalledVoiceModels(installed, system: system)),
        rootfsStoreProvider.overrideWithValue(rootfs),
        installedRootfsProvider.overrideWith(() => InstalledRootfs(scans.first)),
        deviceAbiProvider.overrideWithValue(await abi),
        appVersionProvider.overrideWithValue(await version),
        prootAvailableProvider.overrideWithValue(toolset?.proot != null),
        localModelStoreProvider.overrideWithValue(localModels),
        localLlmProvider.overrideWithValue(server),
        localPrefillProvider.overrideWithValue(prefill),
        installedLocalModelsProvider
            .overrideWith(() => InstalledLocalModels(scans.last)),
        syncHubProvider.overrideWithValue(syncHub),
      ],
    );
    // Arming reconnects for paired devices, so a desktop that has paired once
    // can be dialed again after a restart without opening a window first.
    settingsHome = container;
    // Before `ensureReady`, which starts listening: a peer that lands during
    // it would otherwise run the whole handshake against a hub with no
    // repository and be sent no welcome.
    syncHub.attach(container.read(chatRepositoryProvider));
    await syncHub.ensureReady();
    container.read(availableModelsProvider);
    container.read(turnKeepAliveProvider);
    // The same again for sync: it holds a controller open per chat a paired
    // device is watching, so a turn is visible there, and runs a teleported
    // prompt here.
    container.read(remoteTurnDriverProvider);
    // Read once to set going, like the keep-alive above: it wires itself to the
    // settings and drives the prefill from there.
    container.read(localPrefillTriggerProvider);
    // Sweep expired temporary chats on startup, then every 30 minutes. The
    // timer is in-process and dies with the session: a chat expiring while the
    // app is closed is caught at the next launch. Skips the currently-open
    // chat, which is handled by the on-open prompt.
    Future<void> sweep() => container
        .read(chatRepositoryProvider)
        .sweepExpired(exceptId: container.read(selectedChatIdProvider));
    await sweep();
    // Started, not awaited: catch-up can run turns, and startup must not wait
    // on a model. Whatever it finds overdue was already stamped fired.
    unawaited(container.read(reminderSchedulerProvider).start());
    return AppSession._(
      container,
      Timer.periodic(const Duration(minutes: 30), (_) => sweep()),
    );
  }

  /// Everything of this session that writes: a running turn holds a subprocess,
  /// and the sweep deletes chats. Both stop before the container holding them
  /// goes, which is what lets a restore replace the files underneath.
  Future<void> dispose() async {
    _sweep.cancel();
    await container.read(syncHubProvider).dispose();
    // Before the backend is told to stop, which would abort them.
    await interruptLiveTurns(container);
    await container.read(agentBackendProvider).shutdown();
    // Before the container goes: each is a subprocess holding a gigabyte of the
    // phone's memory, and nothing else would ever kill them.
    await container.read(localLlmProvider).stopAll();
    container.dispose();
  }
}

/// What the container is handed in place of the root, which does not exist yet
/// when the first session is built. Filled in on the root's first frame, and
/// nothing can ask for a restart before there is a button to press.
class AppRelaunch implements AppRestart {
  Future<void> Function({Future<void> Function()? whileStopped})? onRestart;

  /// Unwired, nothing happens — including [whileStopped], so a restore cannot
  /// delete the data directory and then find there is nobody to rebuild it.
  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async =>
      onRestart?.call(whileStopped: whileStopped);
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
  late AppSession? _session = widget.session;

  @override
  void initState() {
    super.initState();
    widget.relaunch.onRestart = _restart;
  }

  Future<void> _restart({Future<void> Function()? whileStopped}) async {
    final old = _session!;
    if (whileStopped != null) {
      // Down to nothing first: what runs here replaces the files the session
      // was built from, so a check that nothing is writing would be a check
      // against writers it does not know about.
      setState(() => _session = null);
      await SchedulerBinding.instance.endOfFrame;
      await old.dispose();
      await whileStopped();
    }
    final next = await AppSession.start(widget.relaunch);
    if (!mounted) return next.dispose();
    setState(() => _session = next);
    // After the frame that takes the old tree down: disposing a container the
    // widgets reading it are still mounted against is disposing it under them.
    if (whileStopped == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    // Only between stopping and starting, which is a restore replacing the
    // files a session would be built from.
    if (session == null) return const _Stopped();
    return UncontrolledProviderScope(
      // Keyed on the session, so a restart builds the tree again rather than
      // reusing state that was reading the container being thrown away.
      key: ObjectKey(session),
      container: session.container,
      child: AgentChatApp(onExit: session.dispose),
    );
  }
}

/// The app with no session behind it. Themed by hand: the palette is a setting,
/// and reading it is what there is nothing to read from here.
class _Stopped extends StatelessWidget {
  const _Stopped();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: appTitle,
        theme: entoliTheme(Brightness.light),
        darkTheme: entoliTheme(Brightness.dark),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
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
    // Both narrowed rather than the settings object: without the `select`,
    // adding a provider or editing an environment variable would rebuild the
    // whole app under the user.
    final mode = ref.watch(appSettingsProvider.select((s) => s.appTheme.mode));
    final look = ref.watch(appLookProvider);
    return MaterialApp(
      title: appTitle,
      theme: entoliTheme(Brightness.light, look),
      darkTheme: entoliTheme(Brightness.dark, look),
      themeMode: mode,
      // All three wrapped rather than folded into the shell: what another app
      // shared has to be offered a workspace over whatever is on screen and the
      // assistant gesture has to open a chat over it, both of which want a
      // Navigator that only exists below here; and the keyboard is the app's to
      // answer for, over whichever field had it.
      home: const FocusFollowsKeyboard(
        child: IncomingAssistant(
          child: IncomingShares(child: IncomingReminderOpen(child: AppShell())),
        ),
      ),
    );
  }
}
