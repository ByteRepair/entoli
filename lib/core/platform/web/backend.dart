import "../../../core/config.dart";
import "../../../domain/agent_backend.dart";
import "../../../data/miniswe/miniswe_pyodide_backend.dart";

AgentBackend createBackend(AppConfig config) => MiniswePyodideBackend(config: config);