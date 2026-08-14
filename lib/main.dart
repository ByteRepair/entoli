import "dart:ui" show AppExitResponse;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "core/config.dart";
import "core/platform/backend.dart" as backend_factory;
import "data/local/local_chat_store.dart";
import "providers.dart";
import "ui/app_shell.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AppConfig.load();
  final store = LocalChatStore(config);
  final backend = backend_factory.createBackend(config);
  final container = ProviderContainer(
    overrides: [
      chatStoreProvider.overrideWithValue(store),
      agentBackendProvider.overrideWithValue(backend),
      appConfigProvider.overrideWithValue(config),
    ],
  );
  container.read(availableModelsProvider);
  runApp(UncontrolledProviderScope(
    container: container,
    child: AgentChatApp(onExit: backend.shutdown),
  ));
}

class AgentChatApp extends StatefulWidget {
  const AgentChatApp({super.key, required this.onExit});

  /// Spawned servers are not our process's children to lose track of: without
  /// this they outlive the app.
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
      title: "agent-chat",
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const AppShell(),
    );
  }
}