import "../../core/config.dart";
import "../../domain/agent_backend.dart";
import "../../domain/prompt_library.dart";
import "io/backend.dart"
    if (dart.library.js_interop) "web/backend.dart"
    as platform;

/// Selects an `AgentBackend` for the current platform.
/// Linux desktop: OpencodeBackend. Android: MinisweChaquopyBackend. Web: MiniswePyodideBackend.
///
/// [library] is the app's commands and agents. A backend that reads such files
/// itself — opencode does — is handed them here, which is the only place that
/// knows both the platform and how its backend expects them.
AgentBackend createBackend(AppConfig config, PromptLibrary library) =>
    platform.createBackend(config, library);