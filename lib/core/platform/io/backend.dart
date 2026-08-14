import "dart:io";

import "../../../core/config.dart";
import "../../../data/miniswe/miniswe_chaquopy_backend.dart";
import "../../../data/opencode/opencode_backend.dart";
import "../../../data/opencode/real_opencode_transport.dart";
import "../../../domain/agent_backend.dart";

/// Desktop runs a real `opencode serve`; Android has no such binary to spawn,
/// so it gets the embedded mini-swe-agent instead.
AgentBackend createBackend(AppConfig config) {
  if (Platform.isAndroid || Platform.isIOS) {
    return MinisweChaquopyBackend(config: config);
  }
  return OpencodeBackend(config: config, transport: RealOpencodeTransport());
}
