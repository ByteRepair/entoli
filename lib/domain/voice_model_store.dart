import "download.dart";
import "installable.dart";
import "voice_model.dart";

/// A voice model as a catalogue row, kept in [store].
class InstallableVoiceModel implements Installable {
  const InstallableVoiceModel(this.model, this.store);

  final VoiceModel model;
  final VoiceModelStore store;

  @override
  String get id => model.id;

  @override
  String get name => model.name;

  @override
  int get bytes => model.bytes;

  @override
  ModelFacts get facts => (
        parameters: model.parameters,
        languages: model.languages,
        bytes: model.bytes,
        quantisation: null,
        context: null,
        voices: switch (model) {
          SpeechModel(:final speakers) => speakers,
          _ => null,
        },
        licence: model.licence,
      );

  @override
  String? get note => model.note;

  @override
  bool get multilingual => model.multilingual;

  @override
  Stream<DownloadProgress> install() => store.install(model);

  @override
  Future<void> delete() => store.delete(model);
}

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
