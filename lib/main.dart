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
import "ui/share/incoming_shares.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await platform.persist();
  final config = await AppConfig.load(platform.createFileSystem(), await platform.dataDir());
  final store = platform.createChatStore(config);
  final library = await PromptLibrary.from(platform.createPromptSources(config));
  final backend = platform.createBackend(config, library, store);
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

class AgentChatApp extends StatefulWidget {
  const AgentChatApp({super.key, required this.onExit});

  /// A running turn holds a subprocess; exiting without this leaves it behind.
  final Future<void> Function() onExit;

  @override
  State<AgentChatApp> createState() => _AgentChatAppState();
}

class _AgentChatAppState extends State<AgentChatApp> {
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
    return MaterialApp(
      title: "Entoli",
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      // Wrapped rather than folded into the shell: what another app shared has
      // to be offered a workspace over whatever is on screen, and a Navigator
      // to push that onto only exists below here.
      home: const IncomingShares(child: AppShell()),
    );
  }
}