import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/local_model.dart";
import "../../providers.dart";
import "downloads.dart";

/// The on-device models' half of [Downloads]. The largest downloads the app
/// makes by an order of magnitude — a couple of gigabytes where a rootfs is
/// four megabytes — which is what makes the notification matter more here than
/// anywhere else it is used.
class LocalModelDownloads extends Downloads<LocalModel> {
  @override
  String idOf(LocalModel model) => model.id;

  /// Every model in the catalog can be fetched wherever there is a server to
  /// run one, so unlike the Linux half there is no architecture to refuse: the
  /// rows are drawn only where `LocalLlm.available`.
  @override
  Download? begin(LocalModel model) => Download(
        bytes: model.bytes,
        progress: ref.read(localModelStoreProvider).install(model),
      );

  @override
  String nameOf(LocalModel model) => model.name;

  @override
  String get plural => "models";

  @override
  Future<void> rescan() =>
      ref.read(installedLocalModelsProvider.notifier).refresh();

  /// Stop serving it before it goes. The load-bearing half of a delete: the
  /// server has the file open, so deleting under it leaves a model answering
  /// out of a file that is no longer there.
  ///
  /// Everything is stopped rather than the one model, and that is the whole
  /// reason there is no `stop(id)`: a delete is rare, whatever else was up
  /// reloads on the next turn that asks for it, and a pool that can be told to
  /// drop one member by name is a second way to get the list wrong.
  @override
  Future<void> unpick(LocalModel model) async {
    final llm = ref.read(localLlmProvider);
    if (!llm.running.value.any((each) => each.modelId == model.id)) return;
    await llm.stopAll();
  }

  @override
  Future<void> erase(LocalModel model) =>
      ref.read(localModelStoreProvider).delete(model.id);
}

final localModelDownloadsProvider =
    NotifierProvider<LocalModelDownloads, DownloadState>(LocalModelDownloads.new);
