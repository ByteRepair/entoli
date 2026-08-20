import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/rootfs.dart";
import "../../providers.dart";
import "downloads.dart";

/// The Linux half of [Downloads]. The one thing it answers that the voice half
/// does not is the architecture: a distribution with no build for this device
/// has nothing to fetch, and says so by starting nothing.
class RootfsDownloads extends Downloads<Rootfs> {
  @override
  String idOf(Rootfs rootfs) => rootfs.id;

  @override
  Download? begin(Rootfs rootfs) {
    final abi = ref.read(deviceAbiProvider);
    final image = rootfs.imageFor(abi);
    if (abi == null || image == null) return null;
    return Download(
      bytes: image.bytes,
      progress: ref.read(rootfsStoreProvider).install(rootfs, abi: abi),
    );
  }

  @override
  String nameOf(String id) => rootfsById(id)?.name ?? "Linux";

  @override
  String several(int count) => "$count systems";

  @override
  Future<void> rescan() => ref.read(installedRootfsProvider.notifier).refresh();

  /// Commands go back to running on Android. Without this the setting would
  /// take the shell all the way to a proot with nothing to chroot into, which
  /// moves the complaint from a settings page to the middle of somebody's turn.
  @override
  Future<void> unpick(Rootfs rootfs) async {
    if (ref.read(appSettingsProvider).rootfsId != rootfs.id) return;
    await ref.read(appSettingsProvider.notifier).setRootfs(null);
  }

  @override
  Future<void> erase(Rootfs rootfs) => ref.read(rootfsStoreProvider).delete(rootfs);
}

final rootfsDownloadsProvider =
    NotifierProvider<RootfsDownloads, DownloadState>(RootfsDownloads.new);
