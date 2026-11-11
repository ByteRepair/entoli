import "dart:convert";

import "../core/config.dart";
import "omada_ordering.dart";
import "permission.dart";
import "settings/keys.dart";
import "settings/setting.dart";
import "temp_chat_ttl.dart";
import "tone.dart";
import "tristate.dart";

export "omada_ordering.dart";

/// A project's own settings, `project.json`: a typed view of its document,
/// where unset inherits the app's. What a project says to its turns is not
/// here: that is the AGENTS.md at its workspace root, read with the
/// instructions.
class ProjectSettings {
  ProjectSettings({
    TempChatTtl? tempChatTtl,
    Map<String, String>? environment,
    Tristate memory = Tristate.inherit,
    bool omada = false,
    OmadaOrdering? omadaOrdering,
    int? omadaMaxGenerations,
    int? turnMaxSteps,
    Tone? tone,
    bool? citations,
    List<PermissionRule> permissions = const [],
    List<String> writableDirs = const [],
    bool? sandbox,
    String? description,
  }) : doc = SettingsDocument() {
    this
      ..tempChatTtl = tempChatTtl
      ..environment = environment
      ..memory = memory
      ..omada = omada
      ..omadaOrdering = omadaOrdering
      ..omadaMaxGenerations = omadaMaxGenerations
      ..turnMaxSteps = turnMaxSteps
      ..tone = tone
      ..citations = citations
      ..permissions = permissions
      ..writableDirs = writableDirs
      ..sandbox = sandbox
      ..description = description;
  }

  ProjectSettings.of(this.doc);

  final SettingsDocument doc;

  TempChatTtl? get tempChatTtl => doc.read(SettingKeys.tempChatTtl);
  set tempChatTtl(TempChatTtl? value) =>
      doc.set(SettingKeys.tempChatTtl, value);

  Map<String, String>? get environment => doc.read(SettingKeys.environment);
  set environment(Map<String, String>? value) =>
      doc.set(SettingKeys.environment, value);

  /// Meaningless for the default project itself, which is the one every
  /// other falls back to.
  Tristate get memory => doc.read(SettingKeys.memory) ?? Tristate.inherit;
  set memory(Tristate value) =>
      doc.set(SettingKeys.memory, value == Tristate.inherit ? null : value);

  bool get omada => doc.read(SettingKeys.omada) ?? false;
  set omada(bool value) => doc.set(SettingKeys.omada, value ? true : null);

  OmadaOrdering? get omadaOrdering => doc.read(SettingKeys.omadaOrdering);
  set omadaOrdering(OmadaOrdering? value) =>
      doc.set(SettingKeys.omadaOrdering, value);

  int? get omadaMaxGenerations => doc.read(SettingKeys.omadaMaxGenerations);
  set omadaMaxGenerations(int? value) =>
      doc.set(SettingKeys.omadaMaxGenerations, value);

  int? get turnMaxSteps => doc.read(SettingKeys.turnMaxSteps);
  set turnMaxSteps(int? value) => doc.set(SettingKeys.turnMaxSteps, value);

  Tone? get tone => doc.read(SettingKeys.tone);
  set tone(Tone? value) => doc.set(SettingKeys.tone, value);

  bool? get citations => doc.read(SettingKeys.citations);
  set citations(bool? value) => doc.set(SettingKeys.citations, value);

  String? get description => doc.read(SettingKeys.description);
  set description(String? value) => doc.set(SettingKeys.description, value);

  List<PermissionRule> get permissions =>
      doc.read(SettingKeys.permissions) ?? const [];
  set permissions(List<PermissionRule> value) =>
      doc.set(SettingKeys.permissions, value);

  List<String> get writableDirs =>
      doc.read(SettingKeys.writableDirs) ?? const [];
  set writableDirs(List<String> value) =>
      doc.set(SettingKeys.writableDirs, value);

  bool? get sandbox => doc.read(SettingKeys.sandbox);
  set sandbox(bool? value) => doc.set(SettingKeys.sandbox, value);

  static ProjectSettings load(AppConfig config, {String? project}) {
    final text = config.documents.read(
      config.projectSettingsFile(project: project),
    );
    if (text == null) return ProjectSettings();
    try {
      return ProjectSettings.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return ProjectSettings();
    }
  }

  factory ProjectSettings.fromJson(Map<String, dynamic> json) =>
      ProjectSettings.of(
        SettingsDocument(json: json, upgrades: SettingKeys.upgrades),
      );

  Future<void> save(AppConfig config, {String? project}) =>
      config.documents.write(
        config.projectSettingsFile(project: project),
        jsonEncode(toJson()),
      );

  Map<String, dynamic> toJson() => doc.toJson();

  ProjectSettings copy() => ProjectSettings.of(doc.copy());
}
