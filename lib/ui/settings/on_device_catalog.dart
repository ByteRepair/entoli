import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/formatting.dart";
import "../../data/local/local_engine.dart" show LocalControl;
import "../../domain/installable.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/catalog.dart";
import "../widgets/section_header.dart";
import "local_model_settings.dart" show AddLocalModelPage;
import "model_downloads.dart";

/// Every model this device can download, text and voice, each kind its own
/// section since they answer separate questions, every row the same
/// [ModelDownloadTile]. A kind nothing here can run is left off rather than
/// listed with nothing to fetch: text models where the build has no server,
/// voice models where the platform has no sherpa (iOS, a browser).
class OnDeviceCatalog extends ConsumerWidget {
  const OnDeviceCatalog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voices = ref.watch(voiceProvider).hasModelCatalog;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ref.watch(localEngineProvider).available) const _TextModels(),
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

/// The catalog, the models added by link, and everything else downloaded.
class _TextModels extends ConsumerWidget {
  const _TextModels();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedLocalModelsProvider);
    final added = ref.watch(addedLocalModelsProvider);
    final engine = ref.watch(localEngineProvider);
    final store = engine.store;
    final offered = [...engine.catalog, ...added];
    final listed = {for (final model in offered) model.id};
    // A model added by link in an earlier session, or one an older catalog
    // offered: kept, and run, until it is deleted.
    final others = [
      for (final model in store.downloadedSync())
        if (!listed.contains(model.id))
          OnDiskModel(id: model.id, name: model.name, source: model.url),
    ];
    final loaded = ref.watch(localLlmStateProvider);
    String deleteMessage(Installable model, {required bool again}) => [
          if (loaded.any((each) => each.modelId == model.id))
            "It is loaded right now. It stops answering, and chats pinned to it "
                "have nothing to run until another model is picked."
          else
            "Chats pinned to it have nothing to run until another model is picked.",
          if (again) "It can be downloaded again.",
        ].join(" ");
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
        for (final model in offered)
          ModelDownloadTile(
            model: InstallableLocalModel(model, store),
            installed: installed.contains(model.id),
            deleteMessage: (m) => deleteMessage(m, again: true),
          ),
        for (final model in others)
          ModelDownloadTile(
            model: InstallableLocalModel(model, store),
            installed: true,
            deleteMessage: (m) => deleteMessage(m, again: false),
          ),
        if (engine.controls.contains(LocalControl.addByLink))
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

/// One voice kind's catalog, every entry listed whether it is installed or
/// not. Recognition and synthesis apart, since a single list would leave the
/// reader working out which ones speak.
class _VoiceModels extends ConsumerWidget {
  const _VoiceModels.recognition()
      : title = "Speech recognition",
        description = "Transcribe speech in voice mode, on this device. "
            "Larger models are more accurate but slower.",
        models = recognitionModels;

  const _VoiceModels.speech()
      : title = "Speech synthesis",
        description = "Read replies aloud, in voice mode or on request, on "
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
/// applies to it — download, cancel, or delete, never more than one at a time.
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
    final progress =
        ref.watch(modelDownloadsProvider.select((s) => s.active[model.id]));
    final failure =
        ref.watch(modelDownloadsProvider.select((s) => s.failures[model.id]));
    final downloads = ref.read(modelDownloadsProvider.notifier);
    return CatalogTile(
      title: Row(
        children: [
          Flexible(child: Text(model.name)),
          if (model.multilingual) ...[
            const SizedBox(width: 8),
            _Badge(label: "Multilingual", tone: Theme.of(context).colorScheme.primary),
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
        onDelete: () => downloads.delete(model),
        onDownload: () => downloads.install(model),
        deleteTitle: "Delete ${model.name}?",
        deleteMessage: deleteMessage(model),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tone),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone),
        ),
      );
}
