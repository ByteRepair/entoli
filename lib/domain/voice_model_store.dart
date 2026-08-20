import "download.dart";
import "voice_model.dart";

/// Where the voice models are kept, and what fetching one costs.
///
/// **Not under the data directory.** Models are re-downloadable, and
/// `backup.dart` zips the data directory whole — a Kokoro and a Whisper base in
/// there would put three hundred megabytes of bytes-you-can-get-again into
/// every export, and a restore, which *replaces* that directory, would drag
/// them across machines and wipe whatever was already downloaded. Keeping them
/// outside is what makes both of those true by construction rather than by a
/// rule in `writeBackup` that someone has to remember.
abstract class VoiceModelStore {
  const VoiceModelStore();

  /// The ids that are installed and whole. A directory a download was killed
  /// halfway through is not one of them: [install] writes its marker last.
  Future<Set<String>> installed();

  /// Where [model]'s files are, or null if it is not installed.
  Future<String?> directoryOf(VoiceModel model);

  /// Fetch [model] and unpack it, reporting as it goes. The stream closes when
  /// the model is installed and errors if it cannot be; **cancelling the
  /// subscription cancels the download** and leaves nothing behind, which is
  /// what the Cancel button does.
  Stream<DownloadProgress> install(VoiceModel model);

  Future<void> delete(VoiceModel model);
}

/// The web's model store: nowhere to put one.
class UnavailableVoiceModelStore extends VoiceModelStore {
  const UnavailableVoiceModelStore();

  @override
  Future<Set<String>> installed() async => const {};

  @override
  Future<String?> directoryOf(VoiceModel model) async => null;

  @override
  Stream<DownloadProgress> install(VoiceModel model) =>
      Stream.error(UnsupportedError("Voice models cannot be downloaded in a browser."));

  @override
  Future<void> delete(VoiceModel model) async {}
}
