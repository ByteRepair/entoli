import "dart:convert";
import "dart:ffi" show Abi;
import "dart:io";

import "package:http/http.dart" as http;
import "package:path/path.dart" as p;
import "package:entoli_core/model/llm_provider.dart";
import "package:entoli_core/model/model_info.dart";
import "package:entoli_core/agent/llm/providers/provider.dart";

import "../mcp_tool_bridge.dart";
import "acp.dart";
import "cli.dart";

/// Antigravity CLI (`agy`) as a provider: the user's Google AI plan
/// answering Entoli's turns. Google keeps the plan's models off its API, so
/// the program is driven as an editor drives it, over ACP (`agy acp`).
class AntigravityCliProvider extends AcpProvider with OfferedByName {
  const AntigravityCliProvider([LlmProviderConfig config = preset])
    : this.over(config);

  /// With where it runs and the tool bridge given rather than real: what a
  /// test runs a session over.
  const AntigravityCliProvider.over(
    super.config, {
    super.guest,
    super.bindBridge = McpToolBridge.bind,
  });

  static const preset = LlmProviderConfig(
    name: "Antigravity CLI",
    api: LlmApi.antigravityCli,
    baseUrl: "",
    defaultModelId: "gemini-4-neon-high",
    defaultLightModelId: "gemini-4-hydrogen-medium",
  );

  @override
  String get defaultCommand => "agy";

  @override
  String get planName => "Google AI";

  @override
  String get serviceName => "Google AI Pro";

  @override
  String get connectHint => "Use your Google AI plan, through Antigravity CLI.";

  @override
  String get workFolder => "antigravity-cli";

  /// The Google sign-in, by the page it prints; a code the page shows is
  /// pasted back.
  @override
  List<String> get signInArguments => const ["acp", "--login"];

  /// It keeps everything under `~/.gemini`, and names no variable to move
  /// it: the home is moved instead.
  @override
  Map<String, String> homeEnvironment(String home) => {
    "HOME": home,
    "USERPROFILE": home,
  };

  @override
  AntigravityCliProvider withConfig(LlmProviderConfig config) =>
      AntigravityCliProvider.over(config, guest: guest, bindBridge: bindBridge);

  @override
  List<String> acpArguments(CliSessionSpec spec) => const ["acp"];

  /// Its permissions are by file: Entoli's server let through, since the
  /// loop has its own approvals, and everything of its own asked about,
  /// which the session refuses.
  @override
  Future<void> prepare() async {
    final file = File(
      p.join(dataDirectory, ".gemini", "antigravity-cli", "settings.json"),
    );
    var settings = <String, dynamic>{};
    if (file.existsSync()) {
      try {
        final read = jsonDecode(await file.readAsString());
        if (read is Map<String, dynamic>) settings = read;
      } on FormatException {
        // Its own file, rewritten whole.
      }
    }
    final permissions = switch (settings["permissions"]) {
      final Map<String, dynamic> map => map,
      _ => <String, dynamic>{},
    };
    final allow = {
      ...?(permissions["allow"] as List?)?.whereType<String>(),
      "mcp(${McpToolRoutes.serverName}/*)",
    };
    settings = {
      ...settings,
      "toolPermission": "request-review",
      "permissions": {...permissions, "allow": allow.toList()},
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings));
  }

  /// Google's own updater's manifests: per platform, the newest version, its
  /// archive and that archive's SHA-512.
  static const manifests =
      "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests";

  @override
  Future<CliRelease?> latestRelease(http.Client client) async {
    final platform = platformOf(abi, musl: musl);
    if (platform == null) return null;
    final manifest = await LlmProvider.getJson(
      Uri.parse("$manifests/$platform.json"),
      headers: const {},
      httpClient: client,
    );
    final url = manifest["url"];
    final hash = manifest["sha512"];
    if (url is! String || hash is! String) {
      throw FormatException("$platform's manifest names no build to fetch");
    }
    return CliRelease(
      files: [
        CliFile(
          name: fileOf(defaultCommand),
          url: Uri.parse(url),
          checksum: CliChecksum.sha512(hash),
          // The program is `antigravity` in its tarball; Windows' is the
          // bare exe.
          packing: url.contains(".tar.gz")
              ? const TarGzProgram(member: "antigravity")
              : const BareProgram(),
        ),
      ],
    );
  }

  /// The manifest [abi]'s build is under: the musl one where the C library
  /// is musl, and on Android, whose Linux is Alpine rather than Bionic;
  /// null for a machine Google builds nothing for.
  static String? platformOf(Abi abi, {bool musl = false}) => switch (abi) {
    Abi.androidArm64 => "linux_arm64_musl",
    Abi.androidX64 => "linux_amd64_musl",
    Abi.macosArm64 => "darwin_arm64",
    Abi.macosX64 => "darwin_amd64",
    Abi.linuxX64 => musl ? "linux_amd64_musl" : "linux_amd64",
    Abi.linuxArm64 => musl ? "linux_arm64_musl" : "linux_arm64",
    Abi.windowsX64 => "windows_amd64",
    Abi.windowsArm64 => "windows_arm64",
    _ => null,
  };

  /// The models a Google AI plan is offered, which depend on the plan; one
  /// missing here is added as the provider's own.
  @override
  List<ModelInfo> get knownModels => _known;

  /// Only Neon's window is published; the rest are taken to be no larger
  /// than the 200k most models of their kind have.
  static final _known = [
    for (final (id, name, context) in const [
      ("gemini-4-neon-high", "Gemini 4 Neon (high)", 512000),
      ("gemini-4-carbon-high", "Gemini 4 Carbon (high)", 200000),
      ("gemini-4-hydrogen-high", "Gemini 4 Hydrogen (high)", 200000),
      ("gemini-4-hydrogen-medium", "Gemini 4 Hydrogen (medium)", 200000),
    ])
      ModelInfo(
        id: id,
        name: name,
        readsImages: true,
        reasoning: true,
        toolCall: true,
        context: context,
      ),
  ];
}
