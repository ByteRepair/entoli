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
    child: const AgentChatApp(),
  ));
}

class AgentChatApp extends StatelessWidget {
  const AgentChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "agent-chat",
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const AppShell(),
    );
  }
}