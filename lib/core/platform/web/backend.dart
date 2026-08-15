import "../../../core/config.dart";
import "../../../domain/agent_backend.dart";
import "../../../domain/prompt_library.dart";
import "../../../data/miniswe/miniswe_pyodide_backend.dart";

// mini-swe-agent has no config directory to lay [library] down in: it is given
// a prompt, so a command will be expanded before it gets there.
AgentBackend createBackend(AppConfig config, PromptLibrary library) =>
    MiniswePyodideBackend(config: config);
