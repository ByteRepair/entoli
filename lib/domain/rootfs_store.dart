import "download.dart";
import "rootfs.dart";

/// Where a downloaded Linux is kept, and what fetching one costs.
///
/// **Not under the data directory**, for the reason the voice models are not:
/// `backup.dart` zips that directory whole, so a rootfs in there would put a
/// few hundred megabytes of bytes-you-can-fetch-again into every export, and a
/// restore — which *replaces* the data directory — would carry one between
/// machines and delete whatever was already installed. Outside it, both are
/// true by construction rather than by a rule someone has to remember.
abstract class RootfsStore {
  const RootfsStore();

  /// The ids that are installed and whole. A directory a download was killed
  /// halfway through is not one of them: [install] writes its marker last.
  Future<Set<String>> installed();

  /// Where [rootfs] is unpacked, or null if it is not installed. The
  /// synchronous twin is what the shell asks before every command, which is why
  /// it exists at all — see [directoryOfSync].
  Future<String?> directoryOf(Rootfs rootfs);

  /// The same answer, without waiting. Every command asks, and a command is
  /// started from a synchronous callback; on this side of the app that costs
  /// one `stat` of a marker file. Null where this platform has no rootfs at all.
  String? directoryOfSync(String id);

  /// Fetch [rootfs] for [abi] and unpack it, reporting as it goes. The stream
  /// closes when it is installed and errors if it cannot be; **cancelling the
  /// subscription cancels the download** and leaves nothing behind, which is
  /// what the Cancel button does.
  Stream<DownloadProgress> install(Rootfs rootfs, {required String abi});

  Future<void> delete(Rootfs rootfs);
}
