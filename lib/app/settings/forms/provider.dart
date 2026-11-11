import "package:uuid/uuid.dart";

import "../../../data/builtin/llm/providers/presets.dart";
import "../../../domain/llm_provider.dart";
import "../controller.dart";

/// What a provider form makes: the endpoint, and the key it is reached with,
/// which goes to the secret store rather than onto the config.
typedef ProviderDraft = ({LlmProviderConfig config, String? key});

/// A provider added or edited by hand: which kind it is, what it is called,
/// where it is, and its key. The Flutter frontend's own dialog asks more of
/// a preset; this is the questions every frontend can ask.
class ProviderForm implements SettingForm<ProviderDraft> {
  ProviderForm(this.provider, {required this.nameTaken});

  final LlmProviderConfig? provider;
  final bool Function(String name) nameTaken;

  static final _presets = [...llmProviderPresets, ...cliProviderPresets];

  @override
  String get title =>
      provider == null ? "Add provider" : "Edit ${provider!.displayName}";

  @override
  Map<String, String> get initial => {
    "kind":
        "${_presets.indexWhere((p) => p.config.api == provider?.api && p.config.baseUrl == provider?.baseUrl).clamp(0, _presets.length - 1)}",
    "name": provider?.name ?? "",
    "baseUrl": provider?.baseUrl ?? _presets.first.config.baseUrl,
    "key": "",
  };

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    final preset = _presets[int.parse(a["kind"]!)];
    return [
      FormChoice("kind", label: "Provider", [
        for (final (i, p) in _presets.indexed) FormOption("$i", p.displayName),
      ]),
      FormText(
        "name",
        "Name",
        hint: preset.displayName,
        error: nameTaken(a["name"]!.trim())
            ? "A provider has that name."
            : null,
      ),
      FormText("baseUrl", "Address", hint: preset.config.baseUrl),
      if (preset.needsKey)
        FormText(
          "key",
          "API key",
          helper: provider == null ? null : "Empty keeps the key it has.",
        ),
    ];
  }

  @override
  String? problem(Map<String, String> a) =>
      nameTaken(a["name"]!.trim()) || a["baseUrl"]!.trim().isEmpty ? "" : null;

  @override
  ProviderDraft build(Map<String, String> a) {
    final preset = _presets[int.parse(a["kind"]!)];
    final name = a["name"]!.trim();
    final key = a["key"]!.trim();
    return (
      config: preset.config.copyWith(
        id: provider?.id ?? const Uuid().v4(),
        name: name.isEmpty ? null : name,
        baseUrl: a["baseUrl"]!.trim(),
      ),
      key: key.isEmpty ? null : key,
    );
  }
}
