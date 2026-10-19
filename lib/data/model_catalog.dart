import "package:flutter/foundation.dart" show compute;
import "package:http/http.dart" as http;

import "../core/config.dart";
import "../core/log.dart";
import "../domain/documents.dart";
import "../domain/model_registry.dart";
import "builtin_models.dart";

final modelsDevUrl = Uri.parse("https://models.dev/api.json");

/// The catalog the app starts with — the presets' defaults, built in — then
/// the cached models.dev over it, then a fresh fetch where [fetch] and the
/// cache is a day old or missing. The file is 6 MB, so a launch does not fetch
/// it every time.
Future<void> loadModelCatalog(AppConfig config, http.Client client,
    {required bool fetch}) async {
  ModelCatalog.notifier.value = ModelCatalog.parse(builtinModelsJson);
  final file = config.fs.file(config.modelsFile);
  DateTime? fetched;
  try {
    if (await file.exists()) {
      // Off the UI isolate, as the fetch's parse is: the cache is most of it.
      ModelCatalog.notifier.value = await compute(ModelCatalog.parse, await file.readAsString());
      fetched = ModelCatalog.current.fetched;
    }
  } catch (e) {
    logFailure("models", "the cached model catalog would not read", e);
  }
  if (!fetch) return;
  if (fetched != null && DateTime.now().difference(fetched) < const Duration(days: 1)) {
    return;
  }
  try {
    final response = await client.get(modelsDevUrl).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      logFailure("models", "models.dev answered ${response.statusCode}");
      return;
    }
    final catalog =
        (await compute(ModelCatalog.parse, response.body)).fetchedAt(DateTime.now());
    ModelCatalog.notifier.value = catalog;
    await writeThroughRename(config.fs, config.modelsFile, catalog.toJsonText());
  } catch (e) {
    logFailure("models", "fetching the model catalog failed", e);
  }
}
