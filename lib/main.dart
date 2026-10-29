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
import "core/tls.dart";
import "data/local/file_trigger_store.dart";
import "data/model_catalog.dart";
import "data/local/file_selector_picker.dart";
import "data/prompts/bundled_skills.dart";
import "data/prompts/prompt_sources.dart" show promptDirsOf;
import "data/sync/file_devices.dart";
import "data/sync/sync_hub.dart";
import "domain/app_restart.dart";
import "domain/app_secrets.dart";
import "domain/app_settings.dart" show AppSettings;
import "domain/trigger_manager.dart" show TriggerRegistryFactory;
import "domain/project.dart" show everyProject;
import "domain/prompt_library.dart";
import "domain/sync/identity.dart";
import "providers.dart";
import "ui/chat/activity/activities.dart" show ChatActivities;
import "ui/chat/activity/activity.dart" show activityCatalogProvider;
import "ui/chat/remote_turns.dart";
import "ui/app_licence.dart";
import "ui/app_shell.dart";
import "ui/initial_setup_gate.dart";
import "ui/routes.dart";
import "ui/welcome_gate.dart";
import "ui/chat/chat_controller.dart";
import "ui/chat/trigger_turn_driver.dart";
import "ui/assistant/incoming_assistant.dart";
import "ui/focus_follows_keyboard.dart";
import "ui/fonts.dart";
import "ui/link_opener.dart";
import "ui/share/incoming_shares.dart";
import "ui/triggers/incoming_open.dart";
import "ui/selection.dart";
import "ui/theme.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledFontLicences();
  registerBundledSkillLicences();
  registerAppLicence();
  platform.registerVoiceLicences();
  platform.registerRecorder();
  await platform.persist();
  // Built here rather than by the root, so the platform's splash covers the
  // first read of the data directory instead of a blank frame.
  final relaunch = AppRelaunch();
  runApp(AppRoot(session: await AppSession.start(relaunch), relaunch: relaunch));
}

/// Whether the automatic update check has run. It belongs to the process, not
/// to a session: a restart a restore builds is this process still running, and
/// running the check again there would download the same release twice and —
/// on Windows — arm a second exit-waiter over the first's.
var _updateChecked = false;

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
    // Started here and awaited below: an asset read off a disk, or a fetch
    // in a browser, and nothing between wants it.
    final version = platform.appVersion();
    // Started here and awaited below: the login shell's PATH, captured once
    // per app run. It is a shell round trip that sources the user's whole
    // profile, so the earlier it starts the more of the startup work above it
    // overlaps — the driver is resolved synchronously per command, so it
    // cannot be asked for there. Null where there is nothing to ask, which
    // leaves the inherited PATH standing.
    final loginPath = platform.captureLoginPath();
    final accent = systemAccent();
    final config = await AppConfig.load(platform.createFileSystem(), await platform.dataDir());
    // Started here and awaited before the identity load below: the keyring
    // probe is decided once, so the identity's own first read must not race
    // this one, and the mirror the registry reads keys through is filled by
    // the time the container reads the model list.
    final secretStore = platform.createSecretStore(config);
    final secrets = AppSecrets(secretStore);
    final secretsLoaded = secrets.load();
    // Before the library is built: the bundled skills are written from
    // embedded code to a real directory for bash access, and self-healed.
    // The writes land inside the install, between its acquire and its
    // release: the previous launch left these directories read-only.
    final projects = everyProject(await config.projectNames());
    await installBundledSkills(config, platform.readOnlyDirs);
    // Read-only so a model running bash cannot unintentionally write to a
    // skill directory. Per project: each project's skills dirs are read-only
    // the way the default's are, since a `bash` command reaches any of them.
    // The bundled roots were locked by the install; this covers the user's
    // `skills/` and `agents/` beside them, which the app writes only through
    // their managers. Every project's tiers, the shared ones once.
    await Future.wait({
      for (final project in projects) ...promptDirsOf(config, project: project),
    }.map((dir) => platform.readOnlyDirs
        .of(dir.path, executable: dir.executable)
        .lock()));
    final store = platform.createChatStore(config);
    // One library per project: the default's is the base set every other
    // project inherits, and a project's own overrides same-named default
    // entries for that project alone. Built once at startup so nothing
    // downstream waits on disk; see "Skills and agents" in
    // `lib/domain/AGENTS.md`. The builds read independent project dirs, so
    // they overlap rather than serialise.
    final libraries = Map.fromEntries(await Future.wait(projects.map((project) async =>
        MapEntry(project,
            await PromptLibrary.from(platform.createPromptSources(config, project: project))))));
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
    // Started here and awaited below with the pool: one channel round trip
    // at launch, so the pickers are honest for the whole session rather than
    // after the first turn. Null wherever the model is not this device's to
    // answer with.
    final appleFm = platform.createAppleFm();
    final toolset = await tools;
    final server = await localLlm;
    // Beside the pool, so the two agree on where the server's slot dumps go.
    final kvCache = platform.createLocalKvCache(cache, server);
    // Where Byte Repair's fetched tools land on the host, and the one
    // directory both the store that fills it and the turns' driver that
    // injects it on PATH are built from.
    final byteRepairBin = platform.byteRepairBinDir(cache);
    final browser = platform.createAgentBrowser(config, cache);
    // The registry the trigger tools run against, assigned like
    // [settingsHome] is: read only from a running app, after the container
    // exists.
    late final TriggerRegistryFactory triggerRegistry;
    late final Future<void> Function(void Function(AppSettings)) editSettings;
    final backend = platform.createBackend(config, libraries, store,
        tools: toolset, rootfs: rootfs, abi: await abi, localLlm: server, kvCache: kvCache,
        appleFm: await appleFm, byteRepairBinDir: byteRepairBin, secrets: secrets,
        loginPath: await loginPath,
        triggerRegistry: (chatId, project) => triggerRegistry(chatId, project),
        editSettings: (change) => editSettings(change),
        browser: browser);
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
    final picks = voice.nativePicks;
    final system = {
      if (picks case (:final recognition, :final speech)) ...[
        if (engines.recognition) recognition,
        if (engines.speech) speech,
      ],
    };
    final installed = {...await scan, ...system};
    // Read here for the reason the voice models are: the Terminal and On-device
    // pages' rows and the pickers above them are drawn from it, and a scan
    // started when the page opens would draw every row as "not installed"
    // first. Both at once — they are two directories and neither needs the
    // other.
    final scans = await Future.wait([rootfs.installed(), localModels.installed()]);
    final triggers = await FileTriggerStore(config).load();
    // Started before the identity load and awaited below, so the session-bus
    // connect on Linux overlaps it rather than serialising behind it; nothing
    // between depends on the answer.
    final alarms = platform.createReminderAlarms();
    // Started alongside the identity load: on Android it is a channel round
    // trip, and the two overlap rather than serialise.
    final hostname = platform.deviceHostname();
    // The one await of the store's own I/O: the identity is the next reader,
    // and the keyring probe must not be raced by a second first read.
    await secretsLoaded;
    final identity = await SyncIdentity.load(secretStore);
    final registry = FileDeviceRegistry(config, secretStore);
    // Assigned two statements down, and read only from a running app — the
    // hub has to exist before the container that overrides its provider.
    late final ProviderContainer settingsHome;
    final syncHub = SyncHub(
      identity: identity,
      registry: registry,
      settings: () => settingsHome.read(appSettingsProvider),
      turnPassword: () => secrets.turnPassword,
      lanSignaling: platform.createLanSignaling,
      hostname: await hostname,
    );
    final container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(store),
        agentBackendProvider.overrideWithValue(backend),
        activityCatalogProvider.overrideWithValue(const ChatActivities()),
        shellProvider.overrideWithValue(backend.shell),
        appConfigProvider.overrideWithValue(config),
        appSecretsProvider.overrideWithValue(secrets),
        attachmentPickerProvider.overrideWithValue(const FileSelectorPicker()),
        // Seed every project's library at startup: each family member gets its
        // own seeded library, so nothing downstream waits on disk.
        promptLibraryProvider.overrideWith2(
            (project) => PromptLibraryNotifier(project, libraries[project])),
        launcherIconsProvider.overrideWithValue(const LauncherAliases()),
        systemAccentProvider.overrideWithValue(await accent),
        linkOpenerProvider
            .overrideWithValue(PlatformLinkOpener(store, syncHub)),
        marketplaceClientProvider.overrideWithValue(tlsClient()),
        backgroundWorkProvider.overrideWithValue(foreground),
        fileHandoffProvider.overrideWithValue(handoff),
        assistantLaunchProvider.overrideWithValue(platform.createAssistantLaunch()),
        reminderAlarmsProvider.overrideWithValue(await alarms),
        triggersProvider.overrideWith(() => Triggers(triggers)),
        triggerTurnDriverProvider
            .overrideWith((ref) => ChatControllerTriggerTurnDriver(ref)),
        backupHandoffProvider
            .overrideWithValue(platform.createBackupHandoff(config, handoff)),
        appRestartProvider.overrideWithValue(relaunch),
        voiceModelStoreProvider.overrideWithValue(voiceModels),
        voiceProvider.overrideWithValue(voice),
        installedVoiceModelsProvider
            .overrideWith(() => InstalledVoiceModels(installed, system: system)),
        rootfsStoreProvider.overrideWithValue(rootfs),
        byteRepairStoreProvider.overrideWithValue(
            platform.createByteRepairStore(config, cache, rootfs)),
        byteRepairBinDirProvider.overrideWithValue(byteRepairBin),
        installedRootfsProvider.overrideWith(() => InstalledRootfs(scans.first)),
        deviceAbiProvider.overrideWithValue(await abi),
        appVersionProvider.overrideWithValue(await version),
        prootAvailableProvider.overrideWithValue(toolset?.proot != null),
        hostConfinementProvider.overrideWithValue(platform.hostConfinement()),
        appUpdateHostProvider
            .overrideWithValue(platform.createAppUpdateHost(cache)),
        agentBrowserProvider.overrideWithValue(browser),
        localModelStoreProvider.overrideWithValue(localModels),
        localLlmProvider.overrideWithValue(server),
        localPrefillProvider.overrideWithValue(prefill),
        installedLocalModelsProvider
            .overrideWith(() => InstalledLocalModels(scans.last)),
        syncHubProvider.overrideWithValue(syncHub),
      ],
    );
    settingsHome = container;
    triggerRegistry = (chatId, project) =>
        ProviderTriggerOwner(container).registryFor(chatId, project);
    editSettings = container.read(appSettingsProvider.notifier).edit;
    // Before `ensureReady`, which starts listening: a peer that lands during
    // it would otherwise run the whole handshake against a hub with no
    // repository and be sent no welcome.
    syncHub.attach(container.read(chatRepositoryProvider));
    await syncHub.ensureReady();
    container.read(availableModelsProvider);
    container.read(turnKeepAliveProvider);
    // Each read once to set going: they listen for the container's life.
    container.read(syncKeepAliveProvider);
    container.read(remoteTurnDriverProvider);
    container.read(localPrefillTriggerProvider);
    container.read(chatDeletionRefreshProvider);
    // The automatic update check, started and not awaited: the release tag is
    // a network round trip and a newer build a download, and startup must not
    // wait on either. Once per process — see [_updateChecked]. Nothing the
    // check does disturbs this process — see "The automatic update" in the
    // root notes — so its timing is the network's to decide.
    if (!_updateChecked) {
      _updateChecked = true;
      unawaited(container.read(appUpdateHostProvider).check(
            version: container.read(appVersionProvider),
            enabled: container.read(appSettingsProvider).autoUpdate,
          ));
    }
    // The model catalog, read from its cache and refreshed in the background.
    // Only a hosted provider sends anything there: on-device models are
    // described by the app itself.
    void loadCatalog() {
      final client = tlsClient();
      unawaited(loadModelCatalog(config, client,
              fetch: container.read(appSettingsProvider).llmProviders.isNotEmpty)
          .whenComplete(client.close));
    }

    loadCatalog();
    // The first provider fetches it then: the welcome tour adds one.
    container.listen(appSettingsProvider.select((s) => s.llmProviders.isNotEmpty),
        (was, now) {
      if (now && was == false) loadCatalog();
    });
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
    unawaited(container.read(triggerManagerProvider).start());
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
    // Left running, it holds the profile the next launch's browser needs.
    await container.read(agentBrowserProvider).close(why: "The app quit.");
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
    try {
      if (whileStopped != null) {
        // Down to nothing first: what runs here replaces the files the session
        // was built from, so a check that nothing is writing would be a check
        // against writers it does not know about.
        setState(() => _session = null);
        await SchedulerBinding.instance.endOfFrame;
        await old.dispose();
        await whileStopped();
      }
    } finally {
      // Even after a failed restore: with no session the app is a spinner
      // until it is killed.
      final next = await AppSession.start(widget.relaunch);
      if (!mounted) {
        await next.dispose();
      } else {
        setState(() => _session = next);
        // After the frame that takes the old tree down: disposing a container
        // the widgets reading it are still mounted against is disposing it
        // under them.
        if (whileStopped == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
        }
      }
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
      // What a turn failure notification is gated on, written where the state
      // is known for the app's whole life rather than asked per chat.
      onStateChange: (state) => ref.read(appHiddenProvider.notifier).set(
            state == AppLifecycleState.hidden ||
                state == AppLifecycleState.detached,
          ),
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
      onGenerateRoute: appRoute,
      // All four wrapped rather than folded into the shell: what another app
      // shared has to be offered a workspace over whatever is on screen and the
      // assistant gesture has to open a chat over it, both of which want a
      // Navigator that only exists below here; the first run is met with the
      // welcome tour (a phone's initial setup ahead of it) over the same, under
      // whatever those two arrive with; and
      // the keyboard is the app's to answer for, over whichever field had it.
      home: const FocusFollowsKeyboard(
        child: IncomingAssistant(
          child: IncomingShares(
            child: IncomingTriggerOpen(
              child: InitialSetupGate(child: WelcomeGate(child: AppShell())),
            ),
          ),
        ),
      ),
    );
  }
}
