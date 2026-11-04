// The Bot Avatars the editor offers: the presets the app ships, each a spec
// in `assets/bot_avatars/presets.json`, and the definitions the user imported,
// kept in `<dataDir>/bot_avatars.json`.
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart" show AssetBundle;

import "../core/log.dart";
import "../domain/bot_avatar/definition.dart";
import "../domain/bot_avatar/spec.dart";
import "../domain/documents.dart" show writeThroughRename;

/// Where the presets are bundled.
const botAvatarPresetsAsset = "assets/bot_avatars/presets.json";

/// The upstream licence the engine and the presets travel under.
const botAvatarLicenceAsset = "assets/bot_avatars/LICENSE.txt";

/// The presets, read through the same spec reader an agent's avatar is: a
/// preset is a spec like any other, and one that fails the contract is
/// skipped with a line rather than taking the rest down.
Future<List<BotAvatarSpec>> loadBotAvatarPresets(AssetBundle bundle) async {
  final list = jsonDecode(await bundle.loadString(botAvatarPresetsAsset));
  final specs = <BotAvatarSpec>[];
  for (final (i, json) in (list as List).indexed) {
    final spec = BotAvatarSpec.fromJson(json);
    spec == null
        ? logFailure("bot-avatar", "preset $i is not a valid spec")
        : specs.add(spec);
  }
  return specs;
}

/// The user's imported definitions, read from and written to [path]. Kept in
/// the order they came in; an import whose id is already there replaces it,
/// the id being what the editor tells two apart.
class BotAvatarLibrary {
  BotAvatarLibrary(this.path);

  final String path;

  Future<List<BotAvatarDefinition>> load() async {
    final file = File(path);
    if (!file.existsSync()) return const [];
    try {
      final list = jsonDecode(await file.readAsString());
      if (list is! List) throw const FormatException("not a list");
      return [
        for (final json in list)
          if (BotAvatarDefinition.validate(json) case BotAvatarValid(
            :final definition,
          ))
            definition,
      ];
    } on Object catch (e) {
      logFailure("bot-avatar", "cannot read the imported avatars: $e");
      return const [];
    }
  }

  Future<void> save(List<BotAvatarDefinition> definitions) async {
    await File(path).parent.create(recursive: true);
    await writeThroughRename(
      path,
      const JsonEncoder.withIndent(
        "  ",
      ).convert([for (final d in definitions) d.toJson()]),
    );
  }

  /// [current] with [added] in, each replacing one of the same id.
  static List<BotAvatarDefinition> merged(
    List<BotAvatarDefinition> current,
    List<BotAvatarDefinition> added,
  ) {
    final ids = {for (final d in added) d.id};
    return [
      for (final d in current)
        if (!ids.contains(d.id)) d,
      ...added,
    ];
  }
}
