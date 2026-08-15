import "dart:io";

import "../../../core/config.dart";
import "../../../data/miniswe/llm/llm_registry.dart";
import "../../../data/miniswe/local_shell.dart";
import "../../../data/miniswe/miniswe_backend.dart";
import "../../../data/opencode/opencode_backend.dart";
import "../../../data/opencode/opencode_config_dir.dart";
import "../../../data/opencode/real_opencode_transport.dart";
import "../../../data/routing_backend.dart";
import "../../../domain/agent_backend.dart";
import "../../../domain/app_settings.dart";
import "../../../domain/chat_store.dart";
import "../../../domain/models.dart";
import "../../../domain/prompt_library.dart";
import "../default_backend.dart";

/// Desktop can run either: a real `opencode serve`, or mini-swe-agent in this
/// process. Android has no opencode binary to spawn, so it only gets the
/// second one.
AgentBackend createBackend(AppConfig config, PromptLibrary library, ChatStore store) {
  // Read when used, not now: the settings page edits these while the app is
  // running, and the next turn has to see the edit.
  AppSettings settings() => AppSettings.load(config);

  final miniswe = MinisweBackend(
    config: config,
    library: library,
    shell: LocalShell(environment: () => settings().opencodeEnv),
    registry: LlmRegistry(
      providers: () => settings().llmProviders,
      // Settings wins, but a key already exported is found without having to
      // be pasted in.
      lookupEnv: (name) => settings().opencodeEnv[name] ?? Platform.environment[name],
    ),
  );

  // The same fact the settings page reads, rather than a second platform test
  // that could disagree with it.
  if (!availableBackendKinds().contains(BackendKind.opencode)) return miniswe;

  // opencode only reads these off disk, and only when a server starts, so the
  // whole library is laid down once here rather than per chat.
  writeOpencodeConfig(library, opencodeConfigDir(config));
  final opencode = OpencodeBackend(
    config: config,
    transport: RealOpencodeTransport(
      environment: () => opencodeEnvironment(config, extra: settings().opencodeEnv),
    ),
  );

  return RoutingBackend(
    backends: {BackendKind.opencode: opencode, BackendKind.miniswe: miniswe},
    defaultKind: () => settings().defaultBackend ?? defaultBackendKind(),
    kindOf: store.backendKindOf,
  );
}
