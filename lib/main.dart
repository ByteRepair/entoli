import "dart:ui" show AppExitResponse;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "core/config.dart";
import "core/platform/app_icon.dart";
import "core/platform/background_work.dart";
import "core/platform/link_opener.dart";
import "core/platform/platform.dart" as platform;
import "data/local/file_selector_picker.dart";
import "domain/prompt_library.dart";
import "providers.dart";
import "ui/app_shell.dart";
import "ui/focus_follows_keyboard.dart";
import "ui/share/incoming_shares.dart";
import "ui/theme.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledFontLicences();
  await platform.persist();
  final config = await AppConfig.load(platform.createFileSystem(), await platform.dataDir());
  final store = platform.createChatStore(config);
  final library = await PromptLibrary.from(platform.createPromptSources(config));
  final backend = platform.createBackend(config, library);
  final container = ProviderContainer(
    overrides: [
      chatStoreProvider.overrideWithValue(store),
      agentBackendProvider.overrideWithValue(backend),
      appConfigProvider.overrideWithValue(config),
      attachmentPickerProvider.overrideWithValue(const FileSelectorPicker()),
      promptLibraryProvider.overrideWithValue(library),
      launcherIconsProvider.overrideWithValue(const LauncherAliases()),
      linkOpenerProvider.overrideWithValue(const PlatformLinkOpener()),
      backgroundWorkProvider.overrideWithValue(ForegroundService()),
      fileHandoffProvider.overrideWithValue(platform.createFileHandoff(config)),
    ],
  );
  container.read(availableModelsProvider);
  container.read(turnKeepAliveProvider);
  runApp(UncontrolledProviderScope(
    container: container,
    child: AgentChatApp(onExit: backend.shutdown),
  ));
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