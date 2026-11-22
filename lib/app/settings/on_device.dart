import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../core/formatting.dart" show nonBlank;
import "../../core/log.dart";
import "../../data/local/local_engine.dart" show LocalEngine;
import "../../data/local/local_instance.dart" show LocalUsage;
import "../../domain/installable.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../../providers.dart";
import "../downloads/model_downloads.dart";

/// The accelerators this device turned out to have, or null where the engine
/// offers no choice. Asked once and kept: it spawns the server with
/// `--list-devices`, and the answer cannot change while the app runs.
final localDevicesProvider = FutureProvider<List<LocalDevice>?>(
  (ref) => ref.watch(localEngineProvider).devices() ?? Future.value(null),
);

/// What the loaded models take up: [total] is the model host's whole
/// footprint where it knows it, the models added up where not.
typedef RunningUsage = ({int? total, Map<String, LocalUsage> each});

/// [RunningUsage], asked again every few seconds while something shows it: a
/// model's cache grows as a chat goes on, and the running list is a place to
/// watch that happen. The clock stops the moment nothing listens, rather
/// than when the provider is let go.
final runningUsageProvider = NotifierProvider<RunningUsageWatch, RunningUsage?>(
  RunningUsageWatch.new,
);

class RunningUsageWatch extends Notifier<RunningUsage?> {
  Timer? _timer;

  // Held from the build: a lifecycle callback, which restarts the clock,
  // may not read the ref.
  late LocalEngine _engine;

  @override
  RunningUsage? build() {
    _engine = ref.watch(localEngineProvider);
    ref.onCancel(_stop);
    ref.onResume(_start);
    ref.onDispose(_stop);
    _start();
    return null;
  }

  void _start() {
    _stop();
    unawaited(_measure());
    _timer = Timer.periodic(_usageRefresh, (_) => unawaited(_measure()));
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The last tick failed: a run of failures is logged once.
  bool _failing = false;

  Future<void> _measure() async {
    final engine = _engine;
    final ids = [for (final state in engine.running.value) state.modelId];
    final List<LocalUsage?> usages;
    final int? footprint;
    try {
      (usages, footprint) = await (
        Future.wait(ids.map(engine.usage)),
        engine.footprint(),
      ).wait;
    } catch (e) {
      if (!_failing) logFailure("local", "could not measure the models", e);
      _failing = true;
      return;
    }
    _failing = false;
    final each = {for (final (i, one) in usages.indexed) ids[i]: ?one};
    final sum = each.isEmpty
        ? null
        : each.values.fold(0, (total, one) => total + one.bytes);
    final total = footprint ?? sum;
    final was = state;
    // A tick that measured the same leaves the pages showing it alone.
    if (!ref.mounted ||
        was != null && was.total == total && mapEquals(was.each, each)) {
      return;
    }
    state = (total: total, each: each);
  }
}

const _usageRefresh = Duration(seconds: 3);

/// Where a model actually ended up, which is the one thing the picker cannot
/// say: Auto is resolved when the model loads, and a phone whose accelerator
/// this build cannot reach answers on the CPU whatever was picked.
String? runningOn(String? device) => switch (device) {
  null => null,
  LocalDevice.cpu => "the CPU",
  final name => "the ${LocalDevice.computeOf(name).label} ($name)",
};

/// What deleting a text model costs: where it is loaded, it stops answering.
String textModelDeleteMessage(
  Installable model,
  List<LocalLlmState> loaded, {
  required bool again,
}) => [
  if (loaded.any((each) => each.modelId == model.id))
    "It is loaded right now. It stops answering, and chats pinned to it "
        "have nothing to run until another model is picked."
  else
    "Chats pinned to it have nothing to run until another model is picked.",
  if (again) "It can be downloaded again.",
].join(" ");

/// Why [url] is not a link a model can be fetched from, or null where it is
/// or nothing is typed yet.
String? modelLinkProblem(String url) {
  final text = url.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  return uri == null ||
          !uri.isScheme("https") && !uri.isScheme("http") ||
          uri.host.isEmpty
      ? "A link starting with https://"
      : null;
}

/// Why [sha256] is not a checksum, or null where it is or is left empty.
String? modelHashProblem(String sha256) {
  final text = sha256.trim();
  return text.isEmpty || RegExp(r"^[0-9a-fA-F]{64}$").hasMatch(text)
      ? null
      : "64 hexadecimal characters";
}

/// A model from any link to a GGUF, added to the list and its download
/// started. Only the link is needed: what the server needs is read off the
/// file once it has arrived.
void addLocalModelByLink(
  T Function<T>(ProviderListenable<T> provider) read, {
  required String url,
  String name = "",
  String parameters = "",
  String licence = "",
  String sha256 = "",
}) {
  final link = url.trim();
  final engine = read(localEngineProvider);
  final taken = {
    for (final model in engine.catalog) model.id,
    for (final model in read(addedLocalModelsProvider)) model.id,
    ...read(installedLocalModelsProvider),
  };
  final model = engine.fromLink!((
    id: localModelIdFor(link, taken),
    name: name.trim(),
    url: link,
    parameters: nonBlank(parameters),
    licence: nonBlank(licence),
    sha256: nonBlank(sha256),
  ));
  read(addedLocalModelsProvider.notifier).add(model);
  read(
    modelDownloadsProvider.notifier,
  ).install(InstallableLocalModel(model, engine.store));
}
