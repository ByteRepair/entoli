import "../../core/config.dart";
import "../../domain/agent_backend.dart";
import "../../domain/chat_store.dart";
import "../../domain/prompt_library.dart";
import "io/backend.dart"
    if (dart.library.js_interop) "web/backend.dart"
    as platform;

/// Selects an `AgentBackend` for the current platform. Desktop can run either
/// opencode or mini-swe-agent and routes per chat; Android and the web only
/// have mini-swe-agent.
///
/// [library] is the app's commands and agents: opencode reads them off disk,
/// mini-swe-agent expands them itself, and this is the only place that knows
/// which is running. [store] says which backend an existing chat belongs to.
AgentBackend createBackend(AppConfig config, PromptLibrary library, ChatStore store) =>
    platform.createBackend(config, library, store);