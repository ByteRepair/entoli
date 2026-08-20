import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../providers.dart";
import "local_model_downloads.dart";
import "../widgets/dialogs.dart";
import "../widgets/formatting.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The accelerators this phone turned out to have. Asked once and kept: it
/// spawns the server with `--list-devices`, and the answer cannot change while
/// the app runs.
final localDevicesProvider = FutureProvider<List<LocalDevice>>(
    (ref) => ref.watch(localLlmProvider).devices());

/// What answers from the device itself: which model is loaded, what it is run
/// on, and how much context it is given. The picker offers only what is on
/// disk, for the reason the voice and terminal pickers do — a choice that fails
/// when it is used rather than when it is made is worse than no choice at all.
class LocalModelSection extends ConsumerWidget {
  const LocalModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localLlmProvider).available) return const _Elsewhere();
    final installed = ref.watch(installedLocalModelsProvider);
    final settings = ref.watch(appSettingsProvider);
    final usable =
        localModelCatalog.where((m) => installed.contains(m.id)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Answering on this device",
          description: "A model downloaded here answers with no network and no "
              "account, and is offered to every chat as another provider. It is "
              "slower and less able than anything hosted, and it is the only one "
              "that works on a plane.",
        ),
        LabelledField(
          label: "Model",
          child: DropdownButton<String?>(
            isExpanded: true,
            // A setting naming a deleted model is a value no item carries,
            // which `DropdownButton` asserts on.
            value: usable.any((m) => m.id == settings.localModelId)
                ? settings.localModelId
                : null,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text("None")),
              for (final model in usable)
                DropdownMenuItem(value: model.id, child: Text(model.name)),
            ],
            onChanged: ref.read(appSettingsProvider.notifier).setLocalModel,
          ),
        ),
        if (settings.localModelId != null) ...[
          const _DevicePicker(),
          const _ContextPicker(),
          const _Status(),
        ],
      ],
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
    final settings = ref.watch(appSettingsProvider);
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
    return LabelledField(
      label: "Runs on",
      child: DropdownButton<String?>(
        isExpanded: true,
        value: devices.any((d) => d.name == settings.localModelDevice)
            ? settings.localModelDevice
            : null,
        items: [
          // Null rather than a device named `CPU`: it is what ggml means by
          // offloading nothing, and it is the only entry that is on every phone.
          const DropdownMenuItem<String?>(value: null, child: Text("CPU")),
          for (final device in devices)
            DropdownMenuItem(
              value: device.name,
              child: Text([
                device.compute.label,
                device.description,
                if (device.totalBytes != null) formatSize(device.totalBytes!),
              ].join(" · ")),
            ),
        ],
        onChanged: ref.read(appSettingsProvider.notifier).setLocalDevice,
      ),
    );
  }
}

/// How much of a conversation the model can see at once, and the one setting
/// here that is really about memory: the weights are mapped and paged, the KV
/// cache is not, so this is what decides whether Android kills the app.
class _ContextPicker extends ConsumerWidget {
  const _ContextPicker();

  static const _choices = [2048, 4096, 8192, 16384, 32768];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final model = localModelById(settings.localModelId);
    final choices =
        _choices.where((n) => model == null || n <= model.contextLength).toList();
    return LabelledField(
      label: "Context",
      child: DropdownButton<int?>(
        isExpanded: true,
        value: choices.contains(settings.localModelContext)
            ? settings.localModelContext
            : null,
        items: [
          const DropdownMenuItem<int?>(value: null, child: Text("Default")),
          for (final size in choices)
            DropdownMenuItem(value: size, child: Text("$size tokens")),
        ],
        onChanged: ref.read(appSettingsProvider.notifier).setLocalContext,
      ),
    );
  }
}

/// How far the server has got. It is the one thing on this page that changes on
/// its own: loading a model takes the better part of a minute, and a model that
/// will not fit says so here and nowhere else.
class _Status extends ConsumerWidget {
  const _Status();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(localLlmStateProvider);
    return switch (state.phase) {
      LocalLlmPhase.off => const SizedBox.shrink(),
      LocalLlmPhase.starting => const ListTile(
          leading: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text("Loading the model…"),
          subtitle: Text("A chat sent before this finishes waits for it."),
        ),
      LocalLlmPhase.ready => ListTile(
          leading: Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
          title: const Text("Answering"),
          subtitle: const Text("Pick it in a chat's settings, or as the app's "
              "default: it is under On-device."),
        ),
      LocalLlmPhase.failed => ListTile(
          isThreeLine: true,
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: const Text("It would not load"),
          subtitle: Text(
            state.failure ?? "",
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
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
      ],
    );
  }
}

/// One model as a row: what it is, what it costs, and the single button that
/// applies to it — download, cancel, or delete, never more than one.
class LocalModelTile extends ConsumerWidget {
  const LocalModelTile({super.key, required this.model});

  final LocalModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Its own row only: a progress event names one model, and watching the
    // whole state would rebuild every tile for it.
    final progress =
        ref.watch(localModelDownloadsProvider.select((s) => s.active[model.id]));
    final failure =
        ref.watch(localModelDownloadsProvider.select((s) => s.failures[model.id]));

    return ListTile(
      isThreeLine: failure != null || progress != null || model.note != null,
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("${model.parameters} · Q4_0 · ${formatSize(model.bytes)} to "
              "download · ${model.licence}"),
          if (model.note != null)
            Text(model.note!, style: theme.textTheme.bodySmall),
          if (failure != null)
            Text(
              failure,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress.fraction),
            const SizedBox(height: 4),
            Text(
              "${formatSize(progress.received)} of ${formatSize(progress.total)}",
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
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
  Widget build(BuildContext context, WidgetRef ref) {
    if (downloading) {
      return IconButton(
        icon: const Icon(Icons.close),
        tooltip: "Cancel",
        onPressed: () =>
            ref.read(localModelDownloadsProvider.notifier).cancel(model.id),
      );
    }
    if (ref.watch(installedLocalModelsProvider).contains(model.id)) {
      return IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: "Delete",
        onPressed: () => _delete(context, ref),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: "Download",
      onPressed: () =>
          ref.read(localModelDownloadsProvider.notifier).install(model),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final loaded = ref.read(appSettingsProvider).localModelId == model.id;
    final ok = await confirm(
      context,
      title: "Delete ${model.name}?",
      message: loaded
          ? "It stops answering, and chats pinned to it have nothing to run "
              "until another model is picked. It can be downloaded again."
          : "It can be downloaded again.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!ok) return;
    await ref.read(localModelDownloadsProvider.notifier).delete(model);
  }
}
