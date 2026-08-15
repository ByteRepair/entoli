import "dart:io";

import "../../../core/config.dart";
import "../../../data/miniswe/miniswe_chaquopy_backend.dart";
import "../../../data/opencode/opencode_backend.dart";
import "../../../data/opencode/opencode_config_dir.dart";
import "../../../data/opencode/real_opencode_transport.dart";
import "../../../domain/agent_backend.dart";
import "../../../domain/app_settings.dart";
import "../../../domain/prompt_library.dart";

/// Desktop runs a real `opencode serve`; Android has no such binary to spawn,
/// so it gets the embedded mini-swe-agent instead.
AgentBackend createBackend(AppConfig config, PromptLibrary library) {
  if (Platform.isAndroid || Platform.isIOS) {
    return MinisweChaquopyBackend(config: config);
  }
  // opencode only reads these off disk, and only when a server starts, so the
  // whole library is laid down once here rather than per chat.
  writeOpencodeConfig(library, opencodeConfigDir(config));
  return OpencodeBackend(
    config: config,
    transport: RealOpencodeTransport(
      // Read off disk at spawn time rather than captured here: the settings
      // page is what writes them, and it does so long after startup.
      environment: () =>
          opencodeEnvironment(config, extra: AppSettings.load(config).opencodeEnv),
    ),
  );
}
