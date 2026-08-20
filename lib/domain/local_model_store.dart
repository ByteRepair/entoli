import "download.dart";
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

  /// The ids that are installed and whole. A directory a download was killed
  /// halfway through is not one of them: [install] writes its marker last.
  Future<Set<String>> installed();

  /// The file to load, or null if it is not installed. Synchronous because that
  /// is what starting the server needs: it is decided from a settings change,
  /// and one `stat` is cheaper than a state that has to be awaited before the
  /// server can be told anything.
  String? fileOfSync(LocalModel model);

  /// Fetch [model], reporting as it goes. The stream closes when it is
  /// installed and errors if it cannot be; **cancelling the subscription
  /// cancels the download** and leaves nothing behind, which is what the Cancel
  /// button does.
  ///
  /// There is no unpacking phase, unlike the other two catalogs: a GGUF is one
  /// file and is used where it lands.
  Stream<DownloadProgress> install(LocalModel model);

  /// By id rather than by [LocalModel], because the ids that most need
  /// deleting are the ones the catalog no longer has: a model dropped or
  /// renamed between releases is still the gigabytes it always was.
  Future<void> delete(String id);
}

/// A browser's model store: nowhere to put a gigabyte, and nothing that could
/// run it if there were.
class UnavailableLocalModelStore extends LocalModelStore {
  const UnavailableLocalModelStore();

  @override
  Future<Set<String>> installed() async => const {};

  @override
  String? fileOfSync(LocalModel model) => null;

  @override
  Stream<DownloadProgress> install(LocalModel model) =>
      Stream.error(UnsupportedError("A model cannot be downloaded here."));

  @override
  Future<void> delete(String id) async {}
}
