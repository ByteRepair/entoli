import "download.dart";
import "installable.dart";
import "local_model.dart";

/// Where a downloaded model is kept, and what fetching one costs.
///
/// **Not under the data directory**, for the reason the voice models and a
/// downloaded Linux are not: `backup.dart` zips that directory whole, so a
/// model in there would put a gigabyte of bytes-you-can-fetch-again into every
/// export, and a restore — which *replaces* the data directory — would carry it
/// between machines and delete whatever was already downloaded. Outside it,
/// both are true by construction rather than by a rule someone has to remember.
abstract class LocalModelStore {
  const LocalModelStore();

  /// The ids that are installed and whole, read again from the disk. A
  /// directory a download was killed halfway through is not one of them:
  /// [install] writes its marker last.
  Future<Set<String>> installed();

  /// Every model on disk, whatever it was fetched from. Synchronous because
  /// that is what starting the server and listing the pickers need, and kept
  /// in step by [install] and [delete] rather than read for every ask.
  List<DownloadedModel> downloadedSync();

  DownloadedModel? downloadedOfSync(String id) {
    for (final model in downloadedSync()) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// Fetch [model], reporting as it goes. The stream closes when it is
  /// installed and errors if it cannot be; **cancelling the subscription
  /// cancels the download** and leaves nothing behind, which is what the Cancel
  /// button does.
  ///
  /// There is no unpacking phase, unlike the other two catalogs: a model's
  /// files are used where they land, once they have said what they are.
  Stream<DownloadProgress> install(LocalModel model);

  /// By id rather than by [LocalModel]: most of what is downloaded is no
  /// catalog entry, and one the catalog has dropped is still the gigabytes it
  /// always was.
  Future<void> delete(String id);
}

/// A text model as a catalogue row, kept in [store]. Once it is on disk its
/// facts are the file's own rather than what the catalogue promised.
class InstallableLocalModel implements Installable {
  const InstallableLocalModel(this.model, this.store);

  final LocalModel model;
  final LocalModelStore store;

  @override
  String get id => model.id;

  @override
  String get name => model.name.isEmpty ? model.id : model.name;

  @override
  int get bytes => model.bytes ?? 0;

  @override
  ModelFacts get facts => switch (store.downloadedOfSync(id)) {
    final DownloadedModel d => (
      parameters: d.parameters,
      languages: null,
      bytes: d.bytes,
      quantisation: d.quantisation,
      context: d.contextLength,
      voices: null,
      licence: d.licence,
    ),
    null => (
      parameters: model.parameters,
      languages: null,
      bytes: model.bytes,
      quantisation: null,
      context: null,
      voices: null,
      licence: model.licence,
    ),
  };

  @override
  String? get note => null;

  @override
  bool get multilingual => false;

  @override
  Stream<DownloadProgress> install() => store.install(model);

  @override
  Future<void> delete() => store.delete(id);
}

/// The store where there is no engine: nothing that could run a model, so
/// nowhere to put one.
class UnavailableLocalModelStore extends LocalModelStore {
  const UnavailableLocalModelStore();

  @override
  Future<Set<String>> installed() async => const {};

  @override
  List<DownloadedModel> downloadedSync() => const [];

  @override
  Stream<DownloadProgress> install(LocalModel model) =>
      Stream.error(UnsupportedError("A model cannot be downloaded here."));

  @override
  Future<void> delete(String id) async {}
}
