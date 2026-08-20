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
  Stream<RootfsProgress> install(Rootfs rootfs, {required String abi});

  Future<void> delete(Rootfs rootfs);
}

/// How far along an install is. [unpacking] is the second phase: a rootfs is
/// thousands of small files and a phone writes them slowly, so a bar that sat
/// at 100% through it would read as a hang.
class RootfsProgress {
  const RootfsProgress({
    required this.received,
    required this.total,
    this.unpacking = false,
  });

  final int received;
  final int total;
  final bool unpacking;

  double? get fraction => total <= 0 ? null : (received / total).clamp(0.0, 1.0);
}

/// The web's rootfs store: nowhere to put one, and nothing that could run it.
class UnavailableRootfsStore extends RootfsStore {
  const UnavailableRootfsStore();

  @override
  Future<Set<String>> installed() async => const {};

  @override
  Future<String?> directoryOf(Rootfs rootfs) async => null;

  @override
  String? directoryOfSync(String id) => null;

  @override
  Stream<RootfsProgress> install(Rootfs rootfs, {required String abi}) =>
      Stream.error(UnsupportedError("A Linux cannot be installed here."));

  @override
  Future<void> delete(Rootfs rootfs) async {}
}
