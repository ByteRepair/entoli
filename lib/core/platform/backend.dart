import "../../core/config.dart";
import "../../domain/agent_backend.dart";
import "io/backend.dart"
    if (dart.library.js_interop) "web/backend.dart"
    as platform;

/// Selects an `AgentBackend` for the current platform.
/// Linux desktop: OpencodeBackend. Android: MinisweChaquopyBackend. Web: MiniswePyodideBackend.
AgentBackend createBackend(AppConfig config) => platform.createBackend(config);