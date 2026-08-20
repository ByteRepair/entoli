import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../providers.dart";
import "local_model_downloads.dart";
import "../widgets/catalog.dart";
import "../widgets/formatting.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The accelerators this phone turned out to have. Asked once and kept: it
/// spawns the server with `--list-devices`, and the answer cannot change while
/// the app runs.
final localDevicesProvider = FutureProvider<List<LocalDevice>>(
    (ref) => ref.watch(localLlmProvider).devices());

/// What answers from the device itself: how many models may be loaded at once,
/// what they run on, and how much context they are given.
///
/// **There is no model picker here, and that is the point.** Every model on
/// disk is offered by the on-device provider, so which one a turn uses is
/// chosen where every other model is — the app default, a chat's own settings,
/// the title and classifier pickers — and asking for one is what loads it. A
/// picker here would have been a second place to say the same thing, and the
/// one place that could disagree with the rest.
class LocalModelSection extends ConsumerWidget {
  const LocalModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localLlmProvider).available) return const _Elsewhere();
    final installed = ref.watch(installedLocalModelsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Answering on this device",
          description: "A model downloaded here answers with no network and no "
              "account, and every one of them is offered to every chat under "
              "On-device. One is loaded when a chat first asks for it. They are "
              "slower and less able than anything hosted, and the only ones "
              "that work on a plane.",
        ),
        if (installed.isEmpty)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text("Nothing downloaded yet"),
            subtitle: Text("Fetch one below and it appears in every model "
                "picker, under On-device."),
          )
        else ...[
          const _MaxRunningPicker(),
          const _DevicePicker(),
          const _ContextPicker(),
          const _Running(),
        ],
      ],
    );
  }
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
      // Null is an answer here rather than an absence: it is what ggml means by
      // offloading nothing, and it is the only entry that is on every phone.
      none: "CPU",
      options: {
        for (final device in devices)
          device.name: [
            device.compute.label,
            device.description,
            if (device.totalBytes != null) formatSize(device.totalBytes!),
          ].join(" · "),
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
        contentPadding: EdgeInsets.zero,
        title: Text("Nothing loaded"),
        subtitle: Text("The first chat to ask for one loads it."),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final state in running) _RunningRow(state),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => ref.read(localLlmProvider).stopAll(),
            child: const Text("Unload all"),
          ),
        ),
      ],
    );
  }
}

class _RunningRow extends StatelessWidget {
  const _RunningRow(this.state);

  final LocalLlmState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = localModelById(state.modelId)?.name ?? state.modelId;
    return switch (state.phase) {
      LocalLlmPhase.starting => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text("Loading $name…"),
          subtitle: const Text("A chat sent before this finishes waits for it."),
        ),
      LocalLlmPhase.ready => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
          title: Text(name),
          subtitle: Text("Answering · ${state.contextLength} tokens of context"),
        ),
      LocalLlmPhase.failed => ListTile(
          contentPadding: EdgeInsets.zero,
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

/// What the section says where no server was bundled, which is every platform
/// but Android. Said rather than hidden, for the reason the Voice category is
/// drawn where `Voice.available` is false: the settings are the app's whatever
/// it is running on, and the answer here is a good one rather than an apology.
class _Elsewhere extends StatelessWidget {
  const _Elsewhere();

  @override
  Widget build(BuildContext context) => const SectionHeader(
        "Answering on this device",
        description: "This build carries no model server. On a desktop the "
            "better answer is already there: add Ollama or LM Studio under "
            "Providers, and everything they serve appears in the pickers. "
            "Carrying a model is Android's, where there is nothing else on the "
            "phone to ask.",
      );
}

/// The catalog, or nothing at all where there is no server to run one. Draws
/// its own divider for the reason the rootfs catalog does: a line with nothing
/// under it is a rule across the bottom of the page.
class LocalModelCatalogSection extends ConsumerWidget {
  const LocalModelCatalogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localLlmProvider).available) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SectionHeader(
          "Available",
          description: "Downloaded once and kept outside the app's data, so a "
              "backup does not carry it and a restore does not delete it. All "
              "of them are Q4_0, which is the one quantisation an NPU can be "
              "handed as it is.",
        ),
        for (final model in localModelCatalog) LocalModelTile(model: model),
        const _StaleModelTiles(),
      ],
    );
  }
}

/// Rows for weights that are installed and no longer in the catalog.
///
/// [LocalModelStore.installed] reads the disk rather than the catalog so these
/// stay findable; this is what makes that reachable rather than only true. A
/// catalog that swaps a generation of models out — which is what it is for —
/// otherwise strands gigabytes behind a file manager, on the platform least
/// likely to have one.
class _StaleModelTiles extends ConsumerWidget {
  const _StaleModelTiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final known = {for (final model in localModelCatalog) model.id};
    final stale = ref.watch(installedLocalModelsProvider)
        .where((id) => !known.contains(id))
        .toList()
      ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final id in stale)
          CatalogTile(
            title: Text(id),
            summary: "Downloaded by an earlier version · not offered any more",
            trailing: _StaleAction(id: id),
          ),
      ],
    );
  }
}

/// Delete and nothing else. There is no [Downloads] entry behind one of these
/// to cancel or fetch again, and nothing to unpick either: a pick naming an id
/// the catalog has lost already stops the server rather than serving it.
class _StaleAction extends ConsumerWidget {
  const _StaleAction({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CatalogAction(
        downloading: false,
        installed: true,
        onCancel: () {},
        onDelete: () async {
          await ref.read(localModelStoreProvider).delete(id);
          await ref.read(installedLocalModelsProvider.notifier).refresh();
        },
        deleteTitle: "Delete $id?",
        deleteMessage: "It is not in the catalog any more, so this app cannot "
            "download it again.",
      );
}

/// One model as a row: what it is, what it costs, and the single button that
/// applies to it — download, cancel, or delete, never more than one.
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

    return CatalogTile(
      title: Text(model.name),
      summary: "${model.parameters} · Q4_0 · ${formatSize(model.bytes)} to "
          "download · ${model.licence}",
      note: model.note,
      failure: failure,
      progress: progress,
      trailing: _Action(model: model, downloading: progress != null),
    );
  }
}

/// Reads what it needs itself rather than being handed it: the installed set
/// does not appear in the row above, and passing it down would rebuild the
/// whole `ListTile` for a button.
class _Action extends ConsumerWidget {
  const _Action({required this.model, required this.downloading});

  final LocalModel model;
  final bool downloading;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CatalogAction(
        downloading: downloading,
        installed: ref.watch(installedLocalModelsProvider).contains(model.id),
        onCancel: () =>
            ref.read(localModelDownloadsProvider.notifier).cancel(model.id),
        onDelete: () =>
            ref.read(localModelDownloadsProvider.notifier).delete(model),
        onDownload: () =>
            ref.read(localModelDownloadsProvider.notifier).install(model),
        deleteTitle: "Delete ${model.name}?",
        deleteMessage: ref
                .watch(localLlmStateProvider)
                .any((each) => each.modelId == model.id)
            ? "It is loaded right now. It stops answering, and chats pinned to "
                "it have nothing to run until another model is picked. It can "
                "be downloaded again."
            : "Chats pinned to it have nothing to run until another model is "
                "picked. It can be downloaded again.",
      );
}
