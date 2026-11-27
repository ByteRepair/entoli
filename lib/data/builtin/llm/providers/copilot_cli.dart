import "dart:ffi" show Abi;

import "package:http/http.dart" as http;
import "package:entoli_core/model/llm_provider.dart";
import "package:entoli_core/model/model_info.dart";
import "package:entoli_core/agent/llm/providers/provider.dart";

import "../mcp_tool_bridge.dart";
import "acp.dart";
import "cli.dart";

/// GitHub Copilot CLI (`copilot`) as a provider: the user's Copilot plan,
/// Microsoft's, answering Entoli's turns. Copilot has no API a third party
/// may call under the plan, so it is driven as an editor drives it, over
/// ACP (`copilot --acp`).
class CopilotCliProvider extends AcpProvider with OfferedByName {
  const CopilotCliProvider([LlmProviderConfig config = preset])
    : this.over(config);

  /// With where it runs and the tool bridge given rather than real: what a
  /// test runs a session over.
  const CopilotCliProvider.over(
    super.config, {
    super.guest,
    super.bindBridge = McpToolBridge.bind,
  });

  static const preset = LlmProviderConfig(
    name: "Copilot CLI",
    api: LlmApi.copilotCli,
    baseUrl: "",
    defaultModelId: "claude-sonnet-4.5",
    defaultLightModelId: "claude-haiku-4.5",
  );

  @override
  String get defaultCommand => "copilot";

  @override
  String get planName => "GitHub Copilot";

  @override
  String get maker => "GitHub";

  /// Copilot Free is a plan too.
  @override
  Set<ProviderTag> get tags => const {
    ProviderTag.privacyControls,
    ProviderTag.paid,
    ProviderTag.free,
  };

  @override
  String get serviceName => "GitHub Copilot";

  @override
  String get connectHint => "Use your Copilot plan, through Copilot CLI.";

  @override
  String get workFolder => "copilot-cli";

  /// The browser sign-in, whose page hands back to a server the program
  /// runs on loopback for as long as it waits.
  @override
  List<String> get signInArguments => const ["login", "--web-flow"];

  /// The machine's own Copilot settings and GitHub tokens are not the
  /// provider's: a token in the environment would sign it in as whoever
  /// that is, and a `COPILOT_MODEL` would pick the model over the chat's.
  @override
  bool inherits(String name, Map<String, String> inherited) =>
      !name.startsWith("COPILOT_") &&
      name != "GH_TOKEN" &&
      name != "GITHUB_TOKEN";

  /// Its config, its sign-in where there is no system credential store, its
  /// logs and sessions.
  @override
  Map<String, String> homeEnvironment(String home) => {"COPILOT_HOME": home};

  @override
  CopilotCliProvider withConfig(LlmProviderConfig config) =>
      CopilotCliProvider.over(config, guest: guest, bindBridge: bindBridge);

  /// Its own tools by the kinds its permissions name, each denied, which
  /// holds whatever else allows them. Read alone is left: in an empty
  /// folder there is nothing of the user's to read.
  static const _denied = ["shell", "write", "url", "memory"];

  @override
  List<String> acpArguments(CliSessionSpec spec) => [
    "--acp",
    "--stdio",
    // Entoli's server, each of its tools, run without a prompt: the loop has
    // its own approvals.
    "--allow-tool=${McpToolRoutes.serverName}",
    for (final kind in _denied) "--deny-tool=$kind",
    "--disable-builtin-mcps",
    "--no-custom-instructions",
    "--no-ask-user",
    "--no-auto-update",
    if (effortOf(spec.reasoningEffort) case final effort?) "--effort=$effort",
  ];

  @override
  bool get modelByEnvironment => true;

  /// The model, where the session offers no choice of it over ACP.
  @override
  Map<String, String> acpEnvironment(CliSessionSpec spec) => {
    if (spec.model.isNotEmpty) "COPILOT_MODEL": spec.model,
  };

  /// GitHub's newest release, whose API states each asset's SHA-256.
  static final latestUrl = Uri.parse(
    "https://api.github.com/repos/github/copilot-cli/releases/latest",
  );

  @override
  Future<CliRelease?> latestRelease(http.Client client) async {
    final target = targetOf(abi, musl: musl);
    if (target == null) return null;
    final windows = target.startsWith("win32");
    final file = (await GitHubRelease.fetch(latestUrl, client)).file(
      "copilot-$target.${windows ? "zip" : "tar.gz"}",
      name: fileOf(defaultCommand),
      packing: windows ? const ZipProgram() : const TarGzProgram(),
    );
    return file == null ? null : CliRelease(files: [file]);
  }

  /// The name [abi]'s build carries, the musl one where the C library is
  /// musl — and on Android, whose Linux is Alpine; null for a machine
  /// GitHub builds nothing for.
  static String? targetOf(Abi abi, {bool musl = false}) => switch (abi) {
    Abi.androidArm64 => "linuxmusl-arm64",
    Abi.androidX64 => "linuxmusl-x64",
    Abi.macosArm64 => "darwin-arm64",
    Abi.macosX64 => "darwin-x64",
    Abi.linuxX64 => musl ? "linuxmusl-x64" : "linux-x64",
    Abi.linuxArm64 => musl ? "linuxmusl-arm64" : "linux-arm64",
    Abi.windowsX64 => "win32-x64",
    Abi.windowsArm64 => "win32-arm64",
    _ => null,
  };

  /// The models a Copilot plan is offered, which depend on the plan and on
  /// what its organisation allows; one missing here is added as the
  /// provider's own. Copilot serves each in a window smaller than its own,
  /// and publishes none of them, so 128k, the one it has long served.
  @override
  List<ModelInfo> get knownModels => _known;

  static final _known = [
    for (final (id, name) in const [
      ("claude-sonnet-4.5", "Claude Sonnet 4.5"),
      ("claude-haiku-4.5", "Claude Haiku 4.5"),
      ("gpt-5.3-codex", "GPT-5.3-Codex"),
      ("gpt-6-astra", "GPT-6-Astra"),
    ])
      ModelInfo(
        id: id,
        name: name,
        readsImages: true,
        reasoning: true,
        toolCall: true,
        context: 128000,
      ),
  ];
}
