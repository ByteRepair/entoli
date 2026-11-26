import "dart:async";

import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/formatting.dart";
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/installable.dart";
import "package:entoli_core/model/local_llm.dart";
import "package:entoli_core/model/local_model.dart";
import "package:entoli_core/model/local_model_store.dart";
import "package:entoli_core/model/model_budget.dart";
import "package:entoli_core/model/voice_model.dart";
import "package:entoli_core/model/voice_model_store.dart";
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/page_bar.dart";

import "../../app/downloads/model_downloads.dart";
import "../../app/settings/on_device.dart";
import "../../data/local/local_engine.dart" show LocalControl;
import "../../data/local/local_instance.dart" show LocalUsage;
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/catalog.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The On-device category: what is loaded first, since it is what is most
/// often come here for, then the row to how text models run, then every
/// model this device can download. A kind nothing here can run is left off:
/// text models where the build has no server, voice models where the
/// platform has no sherpa.
class OnDeviceSection extends ConsumerWidget {
  const OnDeviceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(localEngineProvider);
    final voices = ref.watch(voiceProvider).hasModelCatalog;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (engine.available) ...[
          const _RunningModels(),
          const _DeviceMemory(),
          ListTile(
            title: const Text("LLM settings"),
            subtitle: const Text("Hardware, context and caching"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LocalLlmSettingsPage()),
            ),
          ),
          const Divider(),
          const _TextModels(),
        ] else if (engine.missingFromBuild)
          const SectionHeader(
            "Text models",
            description:
                "This build carries no model server. Run "
                "tool/linux/build-llama.sh and build again, and the catalog "
                "below is bundled into the app. Until then the better answer "
                "is already there: add Ollama or LM Studio under Providers, "
                "and everything they serve appears in the pickers.",
          ),
        if (voices) ...[
          const Divider(),
          const _VoiceModels.recognition(),
          const Divider(),
          const _VoiceModels.speech(),
        ],
      ],
    );
  }
}

/// What is loaded right now: the one thing on the page that changes without
/// being touched. Loading takes the better part of a minute, nothing here
/// started it, and a model that will not fit says so here and nowhere else.
class _RunningModels extends ConsumerWidget {
  const _RunningModels();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(localLlmStateProvider);
    final usage = ref.watch(runningUsageProvider);
    final total = usage?.total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // What the models take up together: the model host's whole footprint
        // on a Mac, where several share it, and elsewhere the rows added up.
        SectionHeader(
          "Running models",
          description: total == null ? null : "${formatSize(total)} in memory",
        ),
        const _Prefilling(),
        if (running.isEmpty)
          const ListTile(
            title: Text("Nothing loaded"),
            subtitle: Text("The first chat to ask for one loads it."),
          )
        else ...[
          for (final state in running)
            _RunningRow(
              state,
              usage?.each[state.modelId],
              key: ValueKey(state.modelId),
            ),
          ListTile(
            title: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => guarded(
                  context,
                  () => ref.read(localEngineProvider).stopAll(),
                ),
                child: const Text("Unload all"),
              ),
            ),
            subtitle: const Text("Frees what every loaded model holds."),
          ),
        ],
      ],
    );
  }
}

/// What the device has to give a model, loaded or not: the readings the
/// catalog's budget is made from, so a catalog that offers nothing shows why.
class _DeviceMemory extends ConsumerWidget {
  const _DeviceMemory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(runningUsageProvider.select((u) => u?.device));
    final graphics = device?.graphics;
    final headroom = device?.headroom;
    if (graphics == null && headroom == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (graphics != null)
          ListTile(
            title: const Text("Graphics memory"),
            subtitle: Text(
              "${formatSize(graphics)} · what the GPU keeps resident before "
              "it pages",
            ),
          ),
        if (headroom != null)
          ListTile(
            title: const Text("App headroom"),
            subtitle: Text(
              "${formatSize(headroom)} · what the system still lets this app "
              "grow by",
            ),
          ),
      ],
    );
  }
}

/// The warm-up in progress, drawn only while there is one. Its own row
/// rather than a line on a model's, because a model can be warming before
/// any chat has loaded one.
class _Prefilling extends ConsumerWidget {
  const _Prefilling();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localPrefillStateProvider);
    if (state == null) return const SizedBox.shrink();
    final pct = switch (state.fraction) {
      final fraction? => " · ${(fraction * 100).round()}%",
      null => "",
    };
    return ListTile(
      leading: const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: Text("Prefilling ${state.name}…"),
      subtitle: Text(
        "Warming its system prompt so the first chat starts sooner$pct",
      ),
    );
  }
}

/// One loaded model: where it answers, what it takes up, and its own Unload.
class _RunningRow extends ConsumerWidget {
  const _RunningRow(this.state, this.usage, {super.key});

  final LocalLlmState state;

  /// What it takes up, where that has been measured.
  final LocalUsage? usage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final engine = ref.watch(localEngineProvider);
    final name = engine.nameOf(state.modelId);
    final where = runningOn(state.device);
    final usage = this.usage;
    // One model let go of, the rest left loaded; a load still under way or
    // one that failed is cleared the same way, so no row is stuck.
    final stop = IconButton(
      icon: const Icon(Icons.stop_circle_outlined),
      tooltip: "Unload $name",
      onPressed: () => guarded(context, () => engine.stop(state.modelId)),
    );
    return switch (state.phase) {
      LocalLlmPhase.starting => ListTile(
        leading: const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text("Loading $name…"),
        subtitle: const Text("A chat sent before this finishes waits for it."),
        trailing: stop,
      ),
      LocalLlmPhase.ready => ListTile(
        leading: Icon(
          Icons.check_circle_outline,
          color: theme.colorScheme.primary,
        ),
        title: Text(name),
        subtitle: Text(
          [
            where == null ? "Answering" : "Answering on $where",
            if (state.contextLength case final context?)
              "${tokenCount(context)} tokens of context",
            if (usage != null) "${formatSize(usage.bytes)} in memory",
            if (usage?.tokens case final tokens? when tokens > 0)
              "${tokenCount(tokens)} tokens cached",
          ].join(" · "),
        ),
        trailing: stop,
      ),
      LocalLlmPhase.failed => ListTile(
        isThreeLine: true,
        leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
        title: Text("$name would not load"),
        subtitle: Text(
          state.failure ?? "",
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        trailing: stop,
      ),
    };
  }
}

/// The catalog, the models added by link, and everything else downloaded.
class _TextModels extends ConsumerWidget {
  const _TextModels();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedLocalModelsProvider);
    final added = ref.watch(addedLocalModelsProvider);
    final engine = ref.watch(localEngineProvider);
    final loaded = ref.watch(localLlmStateProvider);
    final store = engine.store;
    // A catalog entry too heavy for this device is not offered, unless it is
    // downloaded already, which keeps its row and runs as before.
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
    final allowed = engine.budget.bytes;
    final smallest = engine.catalog.map(ModelBudget.footprintOf).minOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Text models",
          description:
              "Run language models offline, on this device. "
              "Downloaded models appear under On-device in every model picker. "
              "They are stored outside the app's data and are not included in "
              "backups.",
        ),
        // The allowance is the launch's reading, while the readings above are
        // live; the subtitle says so rather than leaving the two to disagree.
        if (allowed != null &&
            smallest != null &&
            offered.isEmpty &&
            others.isEmpty)
          ListTile(
            title: const Text(
              "No models fit this device's hardware requirements",
            ),
            subtitle: Text(
              "The smallest needs ${formatSize(smallest)}; this device "
              "allowed ${formatSize(allowed)} when the app started.",
            ),
          ),
        for (final model in offered)
          ModelDownloadTile(
            model: InstallableLocalModel(model, store),
            installed: installed.contains(model.id),
            deleteMessage: (m) =>
                textModelDeleteMessage(m, loaded, again: true),
          ),
        for (final model in others)
          ModelDownloadTile(
            model: InstallableLocalModel(model, store),
            installed: true,
            deleteMessage: (m) =>
                textModelDeleteMessage(m, loaded, again: false),
          ),
        if (engine.fromLink != null)
          AddButtonRow(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add_link),
              label: const Text("Add model"),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AddLocalModelPage()),
              ),
            ),
          ),
      ],
    );
  }
}

/// One voice kind's catalog, every entry listed whether it is installed or
/// not. Recognition and synthesis apart, since a single list would leave the
/// reader working out which ones speak.
class _VoiceModels extends ConsumerWidget {
  const _VoiceModels.recognition()
    : title = "Speech recognition",
      description =
          "Transcribe speech in voice mode, on this device. "
          "Larger models are more accurate but slower.",
      models = recognitionModels;

  const _VoiceModels.speech()
    : title = "Speech synthesis",
      description =
          "Read replies aloud, in voice mode or on request, on "
          "this device.",
      models = speechModels;

  final String title;
  final String description;
  final List<VoiceModel> models;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedVoiceModelsProvider);
    final store = ref.read(voiceModelStoreProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title, description: description),
        for (final model in models)
          ModelDownloadTile(
            model: InstallableVoiceModel(model, store),
            installed: installed.contains(model.id),
            deleteMessage: (m) =>
                "${formatSize(m.bytes)} to download again if you want it back.",
          ),
      ],
    );
  }
}

/// A model as a row: what it is, what it costs, and the one button that
/// applies to it: download, cancel, or delete.
class ModelDownloadTile extends ConsumerWidget {
  const ModelDownloadTile({
    super.key,
    required this.model,
    required this.installed,
    required this.deleteMessage,
  });

  final Installable model;
  final bool installed;
  final String Function(Installable model) deleteMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its own row only: a progress event names one model, and watching the
    // whole state would rebuild every row for it.
    final progress = ref.watch(
      modelDownloadsProvider.select((s) => s.active[model.id]),
    );
    final failure = ref.watch(
      modelDownloadsProvider.select((s) => s.failures[model.id]),
    );
    final downloads = ref.read(modelDownloadsProvider.notifier);
    final tone = Theme.of(context).colorScheme.primary;
    return CatalogTile(
      title: Row(
        children: [
          Flexible(child: Text(model.name)),
          if (model.multilingual) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: tone),
              ),
              child: Text(
                "Multilingual",
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: tone),
              ),
            ),
          ],
        ],
      ),
      tags: modelTags(model.facts),
      note: model.note,
      failure: failure,
      progress: progress,
      trailing: CatalogAction(
        downloading: progress != null,
        installed: installed,
        onCancel: () => downloads.cancel(model.id),
        onDelete: () => guarded(context, () => downloads.delete(model)),
        onDownload: () => downloads.install(model),
        deleteTitle: "Delete ${model.name}?",
        deleteMessage: deleteMessage(model),
      ),
    );
  }
}

/// How on-device text models run: how many may be loaded at once, what they
/// run on, and how much context they are given.
///
/// There is no model picker here: every model on disk is offered by the
/// on-device provider, so which one a turn uses is chosen where every other
/// model is, and asking for one is what loads it.
///
/// Each setting is drawn only where the engine reads it: a [LocalControl] it
/// names, a device list or core count it answers, a prefill it has.
class LocalLlmSettingsPage extends ConsumerWidget {
  const LocalLlmSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(localEngineProvider).controls;
    final prefill = ref.watch(localPrefillProvider) != null;
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    void write(Future<void> Function() change) => guarded(context, change);
    return Scaffold(
      appBar: PageBar(title: "LLM settings"),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // About the device rather than the model: each is its own process
          // holding its own weights and KV cache.
          if (controls.contains(LocalControl.maxRunning))
            InstalledPicker(
              label: "Max LLMs running",
              options: const {
                "1": "One at a time",
                "2":
                    "Two — a small model naming chats beside a large one "
                    "answering them",
              },
              value: "${settings.maxLocalModels}",
              onPick: (count) => write(
                () =>
                    notifier.setMaxLocalModels(int.tryParse(count ?? "") ?? 1),
              ),
            ),
          const _DevicePicker(),
          // The setting here that is really about memory. Unset is per
          // model: what a token of its KV cache costs divided into the budget.
          if (controls.contains(LocalControl.context))
            InstalledPicker(
              label: "Context",
              none: "Per model",
              options: {
                for (final size in const [2048, 4096, 8192, 16384, 32768])
                  "$size": "$size tokens",
              },
              value: settings.localModelContext?.toString(),
              onPick: (size) => write(
                () => notifier.setLocalContext(
                  size == null ? null : int.parse(size),
                ),
              ),
            ),
          const _ThreadsSlider(),
          if (prefill)
            SwitchListTile(
              title: const Text("Prefill the prompt"),
              subtitle: const Text(
                "Warm the default model's system prompt in the background so "
                "the first chat starts sooner. Costs a few minutes of the "
                "processor when the model is set, and shows a notification "
                "while it runs.",
              ),
              value: settings.localModelPrefill,
              onChanged: (on) => write(() => notifier.setLocalPrefill(on)),
            ),
          // One dump is one request to the model, so a turn that runs five
          // commands writes five.
          if (controls.contains(LocalControl.kvCache))
            InstalledPicker(
              label: "Cached prompts",
              description:
                  "Kept across every chat, and a turn writes one for each step "
                  "it takes. The disk budget behind this may allow fewer.",
              none: "Default (${AppSettings.defaultKvCachePrompts})",
              options: const {
                "0": "Off",
                "5": "5 prompts",
                "20": "20 prompts",
                "30": "30 prompts",
                "50": "50 prompts",
              },
              value: settings.localModelKvCachePrompts?.toString(),
              onPick: (prompts) => write(
                () => notifier.setLocalKvCachePrompts(
                  prompts == null ? null : int.parse(prompts),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What runs the arithmetic. Everything but the CPU is discovered, so on
/// most devices this is one entry and says so. Not drawn where the engine
/// offers no choice.
class _DevicePicker extends ConsumerWidget {
  const _DevicePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(localDevicesProvider);
    final picked = ref.watch(
      appSettingsProvider.select((s) => s.localModelDevice),
    );
    // Enumerating spawns the server, so for a second there is no answer yet,
    // and "no accelerator" is a thing to say once rather than take back.
    if (found.isLoading) {
      return const LabelledField(label: "Runs on", child: Text("Looking…"));
    }
    if (found.hasValue && found.value == null) return const SizedBox.shrink();
    final devices = found.asData?.value ?? const [];
    if (devices.isEmpty) {
      return const LabelledField(
        label: "Runs on",
        child: Text("The CPU. This build found no accelerator on this device."),
      );
    }
    return InstalledPicker(
      label: "Runs on",
      // Null is auto, the best accelerator found: the CPU is a choice below
      // the accelerators, the slow option on a device that has one.
      none: "Auto",
      options: {
        for (final device in devices)
          device.name: [
            device.compute.label,
            device.description,
            if (device.totalBytes != null) formatSize(device.totalBytes!),
          ].join(" · "),
        LocalDevice.cpu: "CPU",
      },
      value: picked,
      onPick: (device) => guarded(
        context,
        () => ref.read(appSettingsProvider.notifier).setLocalDevice(device),
      ),
    );
  }
}

/// How many cores the server runs on: every big core by default, fewer
/// trading speed for battery. Drawn only where the machine answered with
/// more than one.
class _ThreadsSlider extends ConsumerStatefulWidget {
  const _ThreadsSlider();

  @override
  ConsumerState<_ThreadsSlider> createState() => _ThreadsSliderState();
}

class _ThreadsSliderState extends ConsumerState<_ThreadsSlider> {
  /// The thumb while it is dragged: the setting is written once the finger
  /// lifts, since each write restarts the server on the next turn.
  double? _dragging;

  /// The top of the range is the default, stored as unset so it tracks the
  /// machine's count.
  void _set(int? threads, int max) => guarded(
    context,
    () => ref
        .read(appSettingsProvider.notifier)
        .setLocalThreads(threads == null || threads >= max ? null : threads),
  );

  @override
  Widget build(BuildContext context) {
    final max = ref.watch(localEngineProvider).maxThreads;
    if (max == null || max <= 1) return const SizedBox.shrink();
    final chosen = ref.watch(
      appSettingsProvider.select((s) => s.localModelThreads),
    );
    final value = _dragging ?? (chosen ?? max).toDouble();
    return LabelledField(
      label: "CPU cores",
      child: ResettableField(
        onReset: () => _set(null, max),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Slider(
              value: value.clamp(1, max.toDouble()),
              min: 1,
              max: max.toDouble(),
              divisions: max - 1,
              label: "${value.round()}",
              onChanged: (v) => setState(() => _dragging = v),
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                _set(v.round(), max);
              },
            ),
            Text(
              chosen == null
                  ? "All $max cores. Fewer is slower but easier on the battery."
                  : "$chosen of $max cores.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A model from any link to a GGUF. Only the link is needed: what the server
/// needs is read off the file once it has arrived, and the rest is what the
/// row will say about it.
class AddLocalModelPage extends ConsumerStatefulWidget {
  const AddLocalModelPage({super.key});

  @override
  ConsumerState<AddLocalModelPage> createState() => _AddLocalModelPageState();
}

class _AddLocalModelPageState extends ConsumerState<AddLocalModelPage> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _parameters = TextEditingController();
  final _licence = TextEditingController();
  final _sha256 = TextEditingController();

  @override
  void dispose() {
    for (final field in [_url, _name, _parameters, _licence, _sha256]) {
      field.dispose();
    }
    super.dispose();
  }

  bool get _ready =>
      _url.text.trim().isNotEmpty &&
      modelLinkProblem(_url.text) == null &&
      modelHashProblem(_sha256.text) == null;

  void _add() {
    addLocalModelByLink(
      ref.read,
      url: _url.text,
      name: _name.text,
      parameters: _parameters.text,
      licence: _licence.text,
      sha256: _sha256.text,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    TextField field(
      TextEditingController controller,
      String label, {
      String? helper,
      String? error,
      bool autofocus = false,
    }) => TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        errorText: error,
      ),
    );
    return Scaffold(
      appBar: PageBar(title: "Add model"),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          field(
            _url,
            "Link",
            helper: "To a .gguf file, e.g. a Hugging Face \"resolve\" link",
            error: modelLinkProblem(_url.text),
            autofocus: true,
          ),
          const SizedBox(height: 16),
          field(_name, "Name", helper: "Empty takes the one inside the file"),
          const SizedBox(height: 16),
          field(
            _parameters,
            "Parameters",
            helper: "As the publisher writes it, e.g. 4B",
          ),
          const SizedBox(height: 16),
          field(_licence, "Licence"),
          const SizedBox(height: 16),
          field(
            _sha256,
            "SHA-256",
            helper: "Checked before the file is kept, where given",
            error: modelHashProblem(_sha256.text),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _ready
                  ? () => guarded(context, () async => _add())
                  : null,
              child: const Text("Download"),
            ),
          ),
        ],
      ),
    );
  }
}
