import "dart:async";

import "package:flutter/foundation.dart";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/formatting.dart";
import "../../../data/local/local_engine.dart" show LocalControl, LocalEngine;
import "../../../data/local/local_instance.dart" show LocalUsage;
import "../../../domain/installable.dart";
import "../../../domain/local_llm.dart";
import "../../../domain/local_model.dart";
import "../../../domain/local_model_store.dart";
import "../../../domain/settings/keys.dart";
import "../../../domain/voice_model.dart";
import "../../../domain/voice_model_store.dart";
import "../../../providers.dart";
import "../../downloads/model_downloads.dart";
import "../controller.dart";
import "../hand_off.dart";
import "../spec.dart";

const _page = SettingsPageId.onDevice;
const _llm = SettingsPageId.onDeviceLlm;

/// The accelerators this device turned out to have, or null where the engine
/// offers no choice. Asked once and kept: it spawns the server with
/// `--list-devices`, and the answer cannot change while the app runs.
final localDevicesProvider = FutureProvider<List<LocalDevice>?>(
  (ref) => ref.watch(localEngineProvider).devices() ?? Future.value(null),
);

final onDeviceSections = [
  // What is loaded leads the page: it is what is most often come here for.
  // What the models take up together: the model host's whole footprint on
  // a Mac, where several models share it and the rows cannot say what is
  // between them, and elsewhere the rows added up.
  SectionSpec(
    page: _page,
    id: "running",
    title: "Running models",
    weight: 0,
    shown: (ref) => ref.watch(localEngineProvider).available,
    describe: (ref) => switch (ref.watch(runningUsageProvider)?.total) {
      final total? => "${formatSize(total)} in memory",
      null => null,
    },
  ),
  // What a build that should have carried a server says, where it did not:
  // what to run to fill it, and the presets meanwhile.
  SectionSpec(
    page: _page,
    id: "noServer",
    title: "Text models",
    weight: 10,
    keepEmpty: true,
    description:
        "This build carries no model server. Run "
        "tool/linux/build-llama.sh and build again, and the catalog "
        "below is bundled into the app. Until then the better answer "
        "is already there: add Ollama or LM Studio under Providers, "
        "and everything they serve appears in the pickers.",
    shown: (ref) {
      final engine = ref.watch(localEngineProvider);
      return !engine.available && engine.missingFromBuild;
    },
  ),
  SectionSpec(
    page: _page,
    id: "textModels",
    title: "Text models",
    weight: 20,
    description:
        "Run language models offline, on this device. "
        "Downloaded models appear under On-device in every model picker. "
        "They are stored outside the app's data and are not included in "
        "backups.",
    shown: (ref) => ref.watch(localEngineProvider).available,
  ),
  SectionSpec(
    page: _page,
    id: "recognition",
    title: "Speech recognition",
    weight: 30,
    description:
        "Transcribe speech in voice mode, on this device. "
        "Larger models are more accurate but slower.",
    shown: (ref) => ref.watch(voiceProvider).hasModelCatalog,
  ),
  SectionSpec(
    page: _page,
    id: "speech",
    title: "Speech synthesis",
    weight: 40,
    description:
        "Read replies aloud, in voice mode or on request, on "
        "this device.",
    shown: (ref) => ref.watch(voiceProvider).hasModelCatalog,
  ),
  const SectionSpec(page: _llm, id: "llm", title: "", weight: 0),
];

/// What deleting a text model costs: where it is loaded, it stops answering.
String _textDeleteMessage(
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

CatalogController _catalog(
  SettingContext c,
  List<(Installable, bool installed, String deleteMessage)> models, {
  String? addLabel,
}) {
  final state = c.ref.watch(modelDownloadsProvider);
  final downloads = c.ref.read(modelDownloadsProvider.notifier);
  final byId = {for (final (model, _, _) in models) model.id: model};
  final add = c.ref.read(settingsHandOffProvider).addModelByLink;
  return CatalogController(
    c.spec,
    items: [
      for (final (model, installed, message) in models)
        CatalogItem(
          id: model.id,
          title: model.name,
          badge: model.multilingual ? "Multilingual" : null,
          facts: model.facts,
          note: model.note,
          failure: state.failures[model.id],
          progress: state.active[model.id],
          installed: installed,
          deleteConfirm: SettingConfirm(
            title: "Delete ${model.name}?",
            message: message,
            confirmLabel: "Delete",
            destructive: true,
          ),
        ),
    ],
    addLabel: add == null ? null : addLabel,
    add: add,
    download: (id) async => downloads.install(byId[id]!),
    cancel: (id) async => downloads.cancel(id),
    delete: (id) => downloads.delete(byId[id]!),
  );
}

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

  Future<void> _measure() async {
    final engine = _engine;
    final ids = [for (final state in engine.running.value) state.modelId];
    final (usages, footprint) = await (
      Future.wait(ids.map(engine.usage)),
      engine.footprint(),
    ).wait;
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
String? _where(String? device) => switch (device) {
  null => null,
  LocalDevice.cpu => "the CPU",
  final name => "the ${LocalDevice.computeOf(name).label} ($name)",
};

final onDeviceSettings = [
  // The warm-up in progress, drawn only while there is one. Its own row
  // rather than a line on a model's, because a model can be warming before
  // any chat has loaded one.
  SettingSpec(
    id: "prefilling",
    path: (page: _page, section: "running"),
    weight: -1,
    title: "Prefilling",
    hint: UiHint.notice,
    build: (c) {
      final state = c.ref.watch(localPrefillStateProvider);
      final pct = switch (state?.fraction) {
        final fraction? => " · ${(fraction * 100).round()}%",
        null => "",
      };
      return NoticeController(
        c.spec,
        visible: state != null,
        lines: [
          if (state != null) NoticeLine("Prefilling ${state.name}…"),
          NoticeLine(
            "Warming its system prompt so the first chat starts sooner$pct",
          ),
        ],
      );
    },
  ),
  SettingSpec(
    id: "runningModels",
    path: (page: _page, section: "running"),
    weight: 0,
    title: "Running",
    hint: UiHint.running,
    build: (c) {
      final running = c.ref.watch(localLlmStateProvider);
      final engine = c.ref.read(localEngineProvider);
      final usage = c.ref.watch(runningUsageProvider)?.each ?? const {};
      return CollectionController<LocalLlmState>(
        c.spec,
        items: running,
        removable: false,
        emptyLabel: "Nothing loaded. The first chat to ask for one loads it.",
        describe: (state) {
          final name = engine.nameOf(state.modelId);
          final where = _where(state.device);
          final used = usage[state.modelId];
          return CollectionItem(
            switch (state.phase) {
              LocalLlmPhase.starting => "Loading $name…",
              LocalLlmPhase.ready => name,
              LocalLlmPhase.failed => "$name would not load",
            },
            id: state.modelId,
            subtitle: switch (state.phase) {
              LocalLlmPhase.starting =>
                "A chat sent before this finishes waits for it.",
              LocalLlmPhase.ready => [
                where == null ? "Answering" : "Answering on $where",
                if (state.contextLength case final context?)
                  "${tokenCount(context)} tokens of context",
                if (used != null) "${formatSize(used.bytes)} in memory",
                if (used?.tokens case final tokens? when tokens > 0)
                  "${tokenCount(tokens)} tokens cached",
              ].join(" · "),
              LocalLlmPhase.failed => null,
            },
            error: state.phase == LocalLlmPhase.failed ? state.failure : null,
            glyph: switch (state.phase) {
              LocalLlmPhase.starting => SettingGlyph.connecting,
              LocalLlmPhase.ready => SettingGlyph.online,
              LocalLlmPhase.failed => SettingGlyph.failed,
            },
            tone: switch (state.phase) {
              LocalLlmPhase.ready => NoticeTone.good,
              LocalLlmPhase.failed => NoticeTone.warning,
              LocalLlmPhase.starting => NoticeTone.plain,
            },
            // One model let go of, the rest left loaded — and a load still
            // under way or one that failed cleared the same way, so no row
            // is stuck.
            actions: [ItemAction("unload", "Unload $name")],
          );
        },
        act: (index, _) async {
          await engine.stop(running[index].modelId);
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "unloadAll",
    path: (page: _page, section: "running"),
    weight: 5,
    title: "Unload all",
    hint: UiHint.button,
    build: (c) {
      final engine = c.ref.read(localEngineProvider);
      final running = c.ref.watch(localLlmStateProvider);
      return ActionController(
        c.spec,
        label: "Unload all",
        secondary: true,
        description: "Frees what every loaded model holds.",
        visible: running.isNotEmpty,
        run: () async {
          await engine.stopAll();
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "onDeviceLlm",
    path: (page: _page, section: "running"),
    weight: 10,
    title: "LLM settings",
    hint: UiHint.row,
    build: (c) => SubpageController(
      c.spec,
      page: _llm,
      summary: "Hardware, context and caching",
    ),
  ),
  SettingSpec(
    id: "textModels",
    path: (page: _page, section: "textModels"),
    weight: 0,
    title: "Text models",
    hint: UiHint.models,
    build: (c) {
      final installed = c.ref.watch(installedLocalModelsProvider);
      final added = c.ref.watch(addedLocalModelsProvider);
      final engine = c.ref.watch(localEngineProvider);
      final loaded = c.ref.watch(localLlmStateProvider);
      final store = engine.store;
      // A catalog entry too heavy for this device is not offered — unless it
      // is downloaded already, which keeps its row and runs as before.
      final offered = [
        for (final model in engine.catalog)
          if (engine.offers(model) || installed.contains(model.id)) model,
        ...added,
      ];
      final listed = {for (final model in offered) model.id};
      // A model added by link in an earlier session, or one an older catalog
      // offered: kept, and run, until it is deleted.
      final others = [
        for (final model in store.downloadedSync())
          if (!listed.contains(model.id))
            OnDiskModel(id: model.id, name: model.name, source: model.url),
      ];
      return _catalog(c, [
        for (final model in offered)
          (
            InstallableLocalModel(model, store),
            installed.contains(model.id),
            _textDeleteMessage(
              InstallableLocalModel(model, store),
              loaded,
              again: true,
            ),
          ),
        for (final model in others)
          (
            InstallableLocalModel(model, store),
            true,
            _textDeleteMessage(
              InstallableLocalModel(model, store),
              loaded,
              again: false,
            ),
          ),
      ], addLabel: engine.fromLink == null ? null : "Add model");
    },
  ),
  for (final (section, models) in [
    ("recognition", recognitionModels),
    ("speech", speechModels),
  ])
    SettingSpec(
      id: "${section}Models",
      path: (page: _page, section: section),
      weight: 0,
      title: section,
      hint: UiHint.models,
      build: (c) {
        final installed = c.ref.watch(installedVoiceModelsProvider);
        final store = c.ref.read(voiceModelStoreProvider);
        return _catalog(c, [
          for (final model in models)
            if (InstallableVoiceModel(model, store) case final installable)
              (
                installable,
                installed.contains(model.id),
                "${formatSize(installable.bytes)} to download again if you "
                    "want it back.",
              ),
        ]);
      },
    ),
  // How many may be resident at once: about the device rather than the
  // model, each its own process holding its own weights and KV cache.
  SettingSpec(
    id: "maxLocalModels",
    path: (page: _llm, section: "llm"),
    weight: 0,
    title: "Max LLMs running",
    hint: UiHint.installed,
    build: (c) => ChoiceController<String>(
      c.spec,
      options: const [
        SettingOption("1", "One at a time"),
        SettingOption(
          "2",
          "Two — a small model naming chats beside a large one answering them",
        ),
      ],
      value: "${c.scope.resolve(SettingKeys.maxLocalModels)}",
      visible: c.ref
          .watch(localEngineProvider)
          .controls
          .contains(LocalControl.maxRunning),
      onSet: (count) async {
        await c.ref
            .read(appSettingsProvider.notifier)
            .setMaxLocalModels(int.tryParse(count ?? "1") ?? 1);
        return null;
      },
    ),
  ),
  // What runs the arithmetic. Everything but the CPU is discovered, so on
  // most devices this is one entry and says so. Not drawn where the engine
  // offers no choice.
  SettingSpec(
    id: "localModelDevice",
    path: (page: _llm, section: "llm"),
    weight: 10,
    title: "Runs on",
    hint: UiHint.installed,
    build: (c) {
      final found = c.ref.watch(localDevicesProvider);
      // Enumerating spawns the server, so for a second there is no answer
      // yet — and "no accelerator" is a thing to say once rather than to say
      // and then take back.
      if (found.isLoading || (found.asData?.value?.isEmpty ?? false)) {
        return NoticeController(
          c.spec,
          lines: [
            NoticeLine(
              found.isLoading
                  ? "Looking…"
                  : "The CPU. This build found no accelerator on this "
                        "device.",
            ),
          ],
        );
      }
      final devices = found.asData?.value;
      return ChoiceController<String>(
        c.spec,
        options: [
          for (final device in devices ?? const <LocalDevice>[])
            SettingOption(
              device.name,
              [
                device.compute.label,
                device.description,
                if (device.totalBytes != null) formatSize(device.totalBytes!),
              ].join(" · "),
            ),
          const SettingOption(LocalDevice.cpu, "CPU"),
        ],
        value: c.scope.resolve(SettingKeys.localModelDevice),
        // Null is auto, the best accelerator found: the CPU is a choice
        // below the accelerators, the slow option on a device that has one.
        noneLabel: "Auto",
        visible: devices != null,
        onSet: (device) async {
          await c.ref.read(appSettingsProvider.notifier).setLocalDevice(device);
          return null;
        },
      );
    },
  ),
  // How much of a conversation a model sees at once: the setting here that
  // is really about memory. The default is per model, what a token of that
  // model's KV cache costs divided into the budget.
  SettingSpec(
    id: "localModelContext",
    path: (page: _llm, section: "llm"),
    weight: 20,
    title: "Context",
    hint: UiHint.installed,
    build: (c) => ChoiceController<String>(
      c.spec,
      options: [
        for (final size in const [2048, 4096, 8192, 16384, 32768])
          SettingOption("$size", "$size tokens"),
      ],
      value: c.scope.resolve(SettingKeys.localModelContext)?.toString(),
      noneLabel: "Per model",
      visible: c.ref
          .watch(localEngineProvider)
          .controls
          .contains(LocalControl.context),
      onSet: (size) async {
        await c.ref
            .read(appSettingsProvider.notifier)
            .setLocalContext(size == null ? null : int.parse(size));
        return null;
      },
    ),
  ),
  // Every big core by default; fewer trades speed for battery. Written when
  // the drag ends, since each write restarts the server on the next turn.
  // The top of the range is the default, stored as unset so it tracks the
  // machine's count.
  SettingSpec(
    id: "localModelThreads",
    path: (page: _llm, section: "llm"),
    weight: 30,
    title: "CPU cores",
    hint: UiHint.slider,
    build: (c) {
      final max = c.ref.watch(localEngineProvider).maxThreads ?? 1;
      final chosen = c.scope.resolve(SettingKeys.localModelThreads);
      return RangeController(
        c.spec,
        value: chosen,
        inherited: max,
        min: 1,
        max: max,
        commitOnEnd: true,
        visible: max > 1,
        footnote: chosen == null
            ? "All $max cores. Fewer is slower but easier on the battery."
            : "$chosen of $max cores.",
        onSet: (threads) async {
          await c.ref
              .read(appSettingsProvider.notifier)
              .setLocalThreads(
                threads == null || threads >= max ? null : threads,
              );
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "localModelPrefill",
    path: (page: _llm, section: "llm"),
    weight: 40,
    title: "Prefill the prompt",
    description:
        "Warm the default model's system prompt in the background so the "
        "first chat starts sooner. Costs a few minutes of the processor when "
        "the model is set, and shows a notification while it runs.",
    hint: UiHint.toggle,
    build: (c) {
      final on = c.scope.resolve(SettingKeys.localModelPrefill)!;
      return ToggleController(
        c.spec,
        value: on,
        effective: on,
        visible: c.ref.watch(localPrefillProvider) != null,
        onSet: (value) async {
          await c.ref
              .read(appSettingsProvider.notifier)
              .setLocalPrefill(value ?? false);
          return null;
        },
      );
    },
  ),
  // How many prompt prefixes are kept warmed on disk, so reopening a chat
  // restores its KV rather than reprocessing it. One dump is one request to
  // the model, so a turn that runs five commands writes five.
  SettingSpec(
    id: "localModelKvCachePrompts",
    path: (page: _llm, section: "llm"),
    weight: 50,
    title: "Cached prompts",
    description:
        "Kept across every chat, and a turn writes one for each step "
        "it takes. The disk budget behind this may allow fewer.",
    hint: UiHint.installed,
    build: (c) => ChoiceController<String>(
      c.spec,
      options: const [
        SettingOption("0", "Off"),
        SettingOption("5", "5 prompts"),
        SettingOption("20", "20 prompts"),
        SettingOption("30", "30 prompts"),
        SettingOption("50", "50 prompts"),
      ],
      value: c.scope.resolve(SettingKeys.localModelKvCachePrompts)?.toString(),
      noneLabel: "Default (${SettingKeys.defaultKvCachePrompts})",
      visible: c.ref
          .watch(localEngineProvider)
          .controls
          .contains(LocalControl.kvCache),
      onSet: (prompts) async {
        await c.ref
            .read(appSettingsProvider.notifier)
            .setLocalKvCachePrompts(
              prompts == null ? null : int.parse(prompts),
            );
        return null;
      },
    ),
  ),
];
