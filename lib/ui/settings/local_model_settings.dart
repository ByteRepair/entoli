import "package:flutter/material.dart";
import "package:flutter/foundation.dart" show defaultTargetPlatform, kIsWeb;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../providers.dart";
import "local_model_downloads.dart";
import "../widgets/add_button_row.dart";
import "../widgets/catalog.dart";
import "../../core/formatting.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The accelerators this phone turned out to have. Asked once and kept: it
/// spawns the server with `--list-devices`, and the answer cannot change while
/// the app runs.
final localDevicesProvider = FutureProvider<List<LocalDevice>>(
    (ref) => ref.watch(localLlmProvider).devices());

/// The row that opens [LocalLlmSettingsPage], kept off the On-device page
/// itself so the catalogs are what it shows.
class LocalModelSection extends ConsumerWidget {
  const LocalModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localLlmProvider).available) {
      return _serverBuilt ? const _Elsewhere() : const SizedBox.shrink();
    }
    return ListTile(
      title: const Text("LLM settings"),
      subtitle: const Text("Hardware, context, caching and loaded models"),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LocalLlmSettingsPage())),
    );
  }
}

/// How on-device text models run: how many may be loaded at once, what they
/// run on, and how much context they are given.
///
/// **There is no model picker here, and that is the point.** Every model on
/// disk is offered by the on-device provider, so which one a turn uses is
/// chosen where every other model is — the app default, a chat's own settings,
/// the title and classifier pickers — and asking for one is what loads it. A
/// picker here would have been a second place to say the same thing, and the
/// one place that could disagree with the rest.
class LocalLlmSettingsPage extends StatelessWidget {
  const LocalLlmSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("LLM settings")),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: const [
            _MaxRunningPicker(),
            _DevicePicker(),
            _ContextPicker(),
            _ThreadsSlider(),
            _PrefillToggle(),
            _KvCachePicker(),
            _Prefilling(),
            _Running(),
          ],
        ),
      );
}

/// How many may be resident at once. The one setting here that is about the
/// phone rather than the model: each is its own process, holding its own
/// weights and its own KV cache.
class _MaxRunningPicker extends ConsumerWidget {
  const _MaxRunningPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appSettingsProvider.select((s) => s.maxLocalModels));
    return InstalledPicker(
      label: "Max LLMs running",
      options: const {
        "1": "One at a time",
        "2": "Two — a small model naming chats beside a large one answering them",
      },
      value: "$value",
      onPick: (count) => ref
          .read(appSettingsProvider.notifier)
          .setMaxLocalModels(int.tryParse(count ?? "1") ?? 1),
    );
  }
}

/// What runs the arithmetic. Everything but the CPU is discovered — see
/// [LocalLlm.devices] — so on most phones this is one entry and says so.
class _DevicePicker extends ConsumerWidget {
  const _DevicePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(localDevicesProvider);
    final picked = ref.watch(appSettingsProvider.select((s) => s.localModelDevice));
    // Enumerating spawns the server, so for a second there is no answer yet —
    // and "no accelerator" is a thing to say once rather than to say and then
    // take back.
    if (found.isLoading) {
      return const LabelledField(label: "Runs on", child: Text("Looking…"));
    }
    final devices = found.asData?.value ?? const [];
    if (devices.isEmpty) {
      return const LabelledField(
        label: "Runs on",
        child: Text("The CPU. This build found no accelerator on this device."),
      );
    }
    return InstalledPicker(
      label: "Runs on",
      // Null is auto, and auto is the best accelerator found — what a turn gets
      // when nobody chooses. The CPU is a choice below the accelerators rather
      // than the default now: on a phone that has one it is the slow option,
      // and the only reason to pick it is to rule the accelerator out.
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
      onPick: ref.read(appSettingsProvider.notifier).setLocalDevice,
    );
  }
}

/// How much of a conversation a model can see at once, and the one setting here
/// that is really about memory: the weights are mapped and paged, the KV cache
/// is not, so this is what decides whether Android kills the app.
///
/// Default is per model rather than one number — `LocalModel.defaultContext`,
/// which is what a token of that model's KV cache costs divided into the
/// budget, so a 2B gets four times the context of a 9B for the same memory.
/// Setting one here overrides that for all of them, which is the honest shape
/// now that any downloaded model can be the one a turn asks for.
class _ContextPicker extends ConsumerWidget {
  const _ContextPicker();

  static const _choices = [2048, 4096, 8192, 16384, 32768];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return InstalledPicker(
      label: "Context",
      none: "Per model",
      options: {for (final size in _choices) "$size": "$size tokens"},
      value: settings.localModelContext?.toString(),
      onPick: (size) => ref
          .read(appSettingsProvider.notifier)
          .setLocalContext(size == null ? null : int.parse(size)),
    );
  }
}

/// How many cores the server runs on. Every big core by default (the reset
/// position); dragging it down trades tokens-per-second for battery, which is
/// the only reason to. Drawn only where the machine answered with more than one
/// — there is nothing to slide on a device that would run on a single core.
class _ThreadsSlider extends ConsumerStatefulWidget {
  const _ThreadsSlider();

  @override
  ConsumerState<_ThreadsSlider> createState() => _ThreadsSliderState();
}

class _ThreadsSliderState extends ConsumerState<_ThreadsSlider> {
  /// The thumb's position while it is being dragged, so the setting is written
  /// once the finger lifts rather than on every pixel — each write restarts the
  /// server on the next turn.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final max = ref.watch(localLlmProvider).maxThreads;
    if (max == null || max <= 1) return const SizedBox.shrink();
    final chosen = ref.watch(appSettingsProvider.select((s) => s.localModelThreads));
    final value = _dragging ?? (chosen ?? max).toDouble();
    return LabelledField(
      label: "CPU cores",
      child: ResettableField(
        onReset: () => ref.read(appSettingsProvider.notifier).setLocalThreads(null),
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
                // The top of the range is the default — store null there so it
                // tracks a machine whose big-core count the OS later reports
                // differently, rather than pinning today's number.
                ref.read(appSettingsProvider.notifier).setLocalThreads(
                    v.round() >= max ? null : v.round());
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

/// How many prompt prefixes to keep warmed on disk, so reopening a chat
/// restores its KV rather than reprocessing it. On by default at ten — the
/// dumps are large, so there is a disk budget behind this and `Off` writes
/// nothing. See "Persisting the KV cache to disk" in AGENTS.md.
///
/// It read "Cached chats" and counted neither chats nor turns: one dump is one
/// request to the model, so a turn that runs five commands writes five, and the
/// bound is over every chat at once. At ten, "10 chats" promised ten
/// conversations kept warm and meant something closer to two.
class _KvCachePicker extends ConsumerWidget {
  const _KvCachePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appSettingsProvider.select((s) => s.localModelKvCachePrompts));
    return InstalledPicker(
      label: "Cached prompts",
      description: "Kept across every chat, and a turn writes one for each step "
          "it takes. The disk budget behind this may allow fewer.",
      none: "Default (${AppSettings.defaultKvCachePrompts})",
      options: const {
        "0": "Off",
        "5": "5 prompts",
        "20": "20 prompts",
        "30": "30 prompts",
        "50": "50 prompts",
      },
      value: value?.toString(),
      onPick: (prompts) => ref
          .read(appSettingsProvider.notifier)
          .setLocalKvCachePrompts(prompts == null ? null : int.parse(prompts)),
    );
  }
}

/// Whether to warm the default on-device model's system prompt in the
/// background. Off by default: on a phone it is minutes of the processor, so it
/// is the user's to ask for. See "Prefilling the system prompt" in AGENTS.md.
class _PrefillToggle extends ConsumerWidget {
  const _PrefillToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(appSettingsProvider.select((s) => s.localModelPrefill));
    return SwitchListTile(
      title: const Text("Prefill the prompt"),
      subtitle: const Text(
          "Warm the default model's system prompt in the background so the "
          "first chat starts sooner. Costs a few minutes of the processor when "
          "the model is set, and shows a notification while it runs."),
      value: on,
      onChanged: ref.read(appSettingsProvider.notifier).setLocalPrefill,
    );
  }
}

/// The warm-up in progress, drawn only while there is one — the rest of the
/// time it has nothing to say. Its own row rather than a line on [_Running]
/// because a model can be warming before any chat has loaded one.
class _Prefilling extends ConsumerWidget {
  const _Prefilling();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localPrefillStateProvider);
    if (state == null) return const SizedBox.shrink();
    final pct =
        state.fraction == null ? "" : " · ${(state.fraction! * 100).round()}%";
    return ListTile(
      leading: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: Text("Prefilling ${state.name}…"),
      subtitle: Text("Warming its system prompt so the first chat starts "
          "sooner$pct"),
    );
  }
}

/// What is loaded right now, one row each. The only thing on this page that
/// changes without being touched: loading takes the better part of a minute,
/// nothing here started it, and a model that will not fit says so here and
/// nowhere else.
class _Running extends ConsumerWidget {
  const _Running();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(localLlmStateProvider);
    if (running.isEmpty) {
      return const ListTile(
        title: Text("Nothing loaded"),
        subtitle: Text("The first chat to ask for one loads it."),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final state in running) _RunningRow(state),
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: TextButton(
            onPressed: () => ref.read(localLlmProvider).stopAll(),
            child: const Text("Unload all"),
          ),
        ),
      ],
    );
  }
}

class _RunningRow extends ConsumerWidget {
  const _RunningRow(this.state);

  final LocalLlmState state;

  /// Where it actually ended up, which is the one thing the picker cannot say:
  /// Auto is resolved when the model loads, and a phone whose accelerator this
  /// build cannot reach answers on the CPU whatever was picked.
  static String? _where(String? device) => switch (device) {
        null => null,
        LocalDevice.cpu => "the CPU",
        final name => "the ${LocalDevice.computeOf(name).label} ($name)",
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = ref.watch(localLlmProvider).nameOf(state.modelId);
    final where = _where(state.device);
    return switch (state.phase) {
      LocalLlmPhase.starting => ListTile(
          leading: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text("Loading $name…"),
          subtitle: const Text("A chat sent before this finishes waits for it."),
        ),
      LocalLlmPhase.ready => ListTile(
          leading: Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
          title: Text(name),
          subtitle: Text("${where == null ? "Answering" : "Answering on $where"}"
              " · ${state.contextLength} tokens of context"),
        ),
      LocalLlmPhase.failed => ListTile(
          isThreeLine: true,
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: Text("$name would not load"),
          subtitle: Text(
            state.failure ?? "",
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ),
    };
  }
}

/// Whether this platform's build carries a model server when it is built
/// whole: Android and Linux. Anywhere else a missing one is not a fault, and
/// the section is not drawn at all.
bool get _serverBuilt =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.linux);

/// What the section says where a build that should have carried a server did
/// not — a build fault in the same sense a missing proot is, said as a line in
/// the section rather than a banner: what to run to fill it, and the presets
/// meanwhile.
class _Elsewhere extends StatelessWidget {
  const _Elsewhere();

  @override
  Widget build(BuildContext context) => const SectionHeader(
        "Text models",
        description: "This build carries no model server. Run "
            "tool/linux/build-llama.sh and build again, and the catalog "
            "below is bundled into the app. Until then the better answer "
            "is already there: add Ollama or LM Studio under Providers, "
            "and everything they serve appears in the pickers.",
      );
}

/// The catalog, the models added by link, and everything else downloaded — or
/// nothing at all where there is no server to run one. Draws its own divider
/// for the reason the rootfs catalog does: a line with nothing under it is a
/// rule across the bottom of the page.
class LocalModelCatalogSection extends ConsumerWidget {
  const LocalModelCatalogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localLlmProvider).available) return const SizedBox.shrink();
    ref.watch(installedLocalModelsProvider);
    final added = ref.watch(addedLocalModelsProvider);
    final listed = {for (final model in [...localModelCatalog, ...added]) model.id};
    final others = [
      for (final model in ref.read(localModelStoreProvider).downloadedSync())
        if (!listed.contains(model.id)) model,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SectionHeader(
          "Text models",
          description: "Run language models offline, on this device. "
              "Downloaded models appear under On-device in every model picker. "
              "They are stored outside the app's data and are not included in "
              "backups.",
        ),
        for (final model in [...localModelCatalog, ...added]) LocalModelTile(model: model),
        for (final model in others) _DownloadedTile(model: model),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add_link),
            label: const Text("Add model"),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AddLocalModelPage())),
          ),
        ),
      ],
    );
  }
}

List<Widget> _downloadedTags(DownloadedModel model) => modelTags(
      parameters: model.parameters,
      bytes: model.bytes,
      quantisation: model.quantisation,
      context: model.contextLength,
      licence: model.licence,
    );

/// One downloadable model as a row: its facts as tags — read off the file once
/// it is downloaded — and the single button that applies to it: download,
/// cancel, or delete, never more than one.
class LocalModelTile extends ConsumerWidget {
  const LocalModelTile({super.key, required this.model});

  final LocalModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its own row only: a progress event names one model, and watching the
    // whole state would rebuild every tile for it.
    final progress =
        ref.watch(localModelDownloadsProvider.select((s) => s.active[model.id]));
    final failure =
        ref.watch(localModelDownloadsProvider.select((s) => s.failures[model.id]));
    final installed = ref.watch(installedLocalModelsProvider).contains(model.id);
    final downloaded =
        installed ? ref.read(localModelStoreProvider).downloadedOfSync(model.id) : null;

    return CatalogTile(
      title: Text(model.name.isEmpty ? model.id : model.name),
      tags: downloaded != null
          ? _downloadedTags(downloaded)
          : modelTags(parameters: model.parameters, bytes: model.bytes, licence: model.licence),
      failure: failure,
      progress: progress,
      trailing: CatalogAction(
        downloading: progress != null,
        installed: installed,
        onCancel: () => ref.read(localModelDownloadsProvider.notifier).cancel(model.id),
        onDelete: () => ref.read(localModelDownloadsProvider.notifier).delete(model),
        onDownload: () => ref.read(localModelDownloadsProvider.notifier).install(model),
        deleteTitle: "Delete ${model.name.isEmpty ? model.id : model.name}?",
        deleteMessage: _deleteMessage(ref, model.id, again: true),
      ),
    );
  }
}

/// A downloaded model the catalog does not offer: one added by link in an
/// earlier session, or one an older catalog offered. Kept, and run, until it
/// is deleted.
class _DownloadedTile extends ConsumerWidget {
  const _DownloadedTile({required this.model});

  final DownloadedModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CatalogTile(
        title: Text(model.name),
        tags: _downloadedTags(model),
        trailing: CatalogAction(
          downloading: false,
          installed: true,
          onCancel: () {},
          onDelete: () => ref
              .read(localModelDownloadsProvider.notifier)
              .delete(LocalModel(id: model.id, name: model.name, url: model.url ?? "")),
          deleteTitle: "Delete ${model.name}?",
          deleteMessage: _deleteMessage(ref, model.id, again: false),
        ),
      );
}

String _deleteMessage(WidgetRef ref, String id, {required bool again}) => [
      if (ref.watch(localLlmStateProvider).any((each) => each.modelId == id))
        "It is loaded right now. It stops answering, and chats pinned to it have "
            "nothing to run until another model is picked."
      else
        "Chats pinned to it have nothing to run until another model is picked.",
      if (again) "It can be downloaded again.",
    ].join(" ");

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

  String? get _urlError {
    final text = _url.text.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    return uri == null || !uri.isScheme("https") && !uri.isScheme("http") || uri.host.isEmpty
        ? "A link starting with https://"
        : null;
  }

  String? get _shaError {
    final text = _sha256.text.trim();
    return text.isEmpty || RegExp(r"^[0-9a-fA-F]{64}$").hasMatch(text)
        ? null
        : "64 hexadecimal characters";
  }

  bool get _ready => _url.text.trim().isNotEmpty && _urlError == null && _shaError == null;

  void _add() {
    String? optional(TextEditingController field) =>
        field.text.trim().isEmpty ? null : field.text.trim();
    final url = _url.text.trim();
    final taken = {
      for (final model in localModelCatalog) model.id,
      for (final model in ref.read(addedLocalModelsProvider)) model.id,
      ...ref.read(installedLocalModelsProvider),
    };
    final model = LocalModel(
      id: localModelIdFor(url, taken),
      name: _name.text.trim(),
      url: url,
      parameters: optional(_parameters),
      licence: optional(_licence),
      sha256: optional(_sha256),
    );
    ref.read(addedLocalModelsProvider.notifier).add(model);
    ref.read(localModelDownloadsProvider.notifier).install(model);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    TextField field(TextEditingController controller, String label,
            {String? helper, String? error, bool autofocus = false}) =>
        TextField(
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
      appBar: AppBar(title: const Text("Add model")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          field(_url, "Link",
              helper: "To a .gguf file, e.g. a Hugging Face \"resolve\" link",
              error: _urlError,
              autofocus: true),
          const SizedBox(height: 16),
          field(_name, "Name", helper: "Empty takes the one inside the file"),
          const SizedBox(height: 16),
          field(_parameters, "Parameters", helper: "As the publisher writes it, e.g. 4B"),
          const SizedBox(height: 16),
          field(_licence, "Licence"),
          const SizedBox(height: 16),
          field(_sha256, "SHA-256",
              helper: "Checked before the file is kept, where given",
              error: _shaError),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _ready ? _add : null,
              child: const Text("Download"),
            ),
          ),
        ],
      ),
    );
  }
}
