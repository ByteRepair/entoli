import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart" show compute;
import "package:http/http.dart" as http;
import "package:entoli_core/model/config.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/documents.dart";
import "package:entoli_core/model/model_registry.dart";

import "builtin_models.dart";

final modelsDevUrl = Uri.parse("https://models.dev/api.json");

/// The catalog the app starts with: the presets' defaults, built in, then
/// the cached models.dev over it.
Future<void> loadModelCatalog(AppConfig config) async {
  ModelCatalog.notifier.value = ModelCatalog.parse(builtinModelsJson);
  final file = File(config.modelsFile);
  try {
    if (file.existsSync()) {
      // Off the UI isolate, as the fetch's parse is: the cache is most of it.
      ModelCatalog.notifier.value = await compute(
        ModelCatalog.parse,
        await file.readAsString(),
      );
    }
  } catch (e) {
    logFailure("models", "the cached model catalog would not read", e);
  }
}

/// Whether the catalog in hand is a day old or was never fetched. The file is
/// 6 MB, so it is not fetched more often than that.
bool get modelCatalogStale {
  final fetched = ModelCatalog.current.fetched;
  return fetched == null ||
      DateTime.now().difference(fetched) >= const Duration(days: 1);
}

/// A fresh models.dev over the catalog in hand.
Future<void> refreshModelCatalog(AppConfig config, http.Client client) async {
  try {
    final response = await client
        .get(modelsDevUrl)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      logFailure("models", "models.dev answered ${response.statusCode}");
      return;
    }
    final catalog = (await compute(
      ModelCatalog.parse,
      response.body,
    )).fetchedAt(DateTime.now());
    ModelCatalog.notifier.value = catalog;
    await writeThroughRename(
      config.fs,
      config.modelsFile,
      utf8.encode(catalog.toJsonText()),
    );
  } catch (e) {
    logFailure("models", "fetching the model catalog failed", e);
  }
}
