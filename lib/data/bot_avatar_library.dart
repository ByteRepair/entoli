// The Bot Avatars the editor offers: the presets the app ships — Entoli's
// own in `assets/bot_avatars/presets.json`, then Open Bot Avatar's in
// `assets/bot_avatars/open-bot-avatar/` — and the definitions the user
// imported, kept in `<dataDir>/bot_avatars.json`.
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart" show AssetBundle;

import "../core/log.dart";
import "../domain/bot_avatar/definition.dart";
import "../domain/bot_avatar/spec.dart";
import "../domain/documents.dart" show RenameWriter;

/// Where the presets are bundled, in the order the editor offers them:
/// Entoli's own first, then the ones taken from Open Bot Avatar, which keep
/// their own directory with the licence they came under.
const botAvatarPresetAssets = [
  "assets/bot_avatars/presets.json",
  "assets/bot_avatars/open-bot-avatar/presets.json",
];

/// The upstream licence the engine and its presets travel under.
const botAvatarLicenceAsset = "assets/bot_avatars/open-bot-avatar/LICENSE.txt";

/// The presets, read through the same spec reader an agent's avatar is: a
/// preset is a spec like any other, and one that fails the contract is
/// skipped with a line rather than taking the rest down.
Future<List<BotAvatarSpec>> loadBotAvatarPresets(AssetBundle bundle) async {
  final specs = <BotAvatarSpec>[];
  for (final asset in botAvatarPresetAssets) {
    final list = jsonDecode(await bundle.loadString(asset));
    for (final (i, json) in (list as List).indexed) {
      final spec = BotAvatarSpec.fromJson(json);
      spec == null
          ? logFailure("bot-avatar", "preset $i of $asset is not a valid spec")
          : specs.add(spec);
    }
  }
  return specs;
}

/// The user's imported definitions, read from and written to [path]. Kept in
/// the order they came in; an import whose id is already there replaces it,
/// the id being what the editor tells two apart. A change is a read, an edit
/// and a write in one queue, the way `LinkedInstructionsStore`'s is: two
/// quick imports would otherwise each write back what the other had not seen.
class BotAvatarLibrary {
  BotAvatarLibrary(this.path);

  final String path;
  final _writer = RenameWriter();
  Future<void> _queue = Future.value();

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
      logFailure("bot-avatar", "cannot read the imported avatars", e);
      return const [];
    }
  }

  /// [definitions] in, each replacing an import of the same id. What the
  /// library holds after.
  Future<List<BotAvatarDefinition>> add(
    List<BotAvatarDefinition> definitions,
  ) => _update((current) {
    final ids = {for (final d in definitions) d.id};
    return [
      for (final d in current)
        if (!ids.contains(d.id)) d,
      ...definitions,
    ];
  });

  /// The import [id] out. What the library holds after.
  Future<List<BotAvatarDefinition>> remove(String id) => _update(
    (current) => [
      for (final d in current)
        if (d.id != id) d,
    ],
  );

  Future<List<BotAvatarDefinition>> _update(
    List<BotAvatarDefinition> Function(List<BotAvatarDefinition>) change,
  ) {
    final next = _queue.then((_) async {
      final updated = change(await load());
      await File(path).parent.create(recursive: true);
      await _writer.write(
        path,
        const JsonEncoder.withIndent(
          "  ",
        ).convert([for (final d in updated) d.toJson()]),
      );
      return updated;
    });
    _queue = next.then<void>((_) {}).catchError((_) {});
    return next;
  }
}
