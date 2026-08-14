import "../../../core/config.dart";
import "../../../domain/agent_backend.dart";
import "../../../data/opencode/opencode_backend.dart";
import "../../../data/opencode/real_opencode_transport.dart";

AgentBackend createBackend(AppConfig config) {
  return OpencodeBackend(
    config: config,
    transport: RealOpencodeTransport(),
  );
}