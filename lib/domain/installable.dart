import "download.dart";

/// What a catalogue row says of a model, each where it is known.
typedef ModelFacts = ({
  String? parameters,
  String? languages,
  int? bytes,
  String? quantisation,
  int? context,
  int? voices,
  String? licence,
});

/// A model whose weights are fetched to this device, and fetched and deleted
/// through the store that keeps its kind. A text model and a voice model are
/// both one, so one catalogue and one download queue serve either.
abstract interface class Installable {
  /// What it is filed under on disk, and the model id it is picked by.
  String get id;

  String get name;

  /// What the download costs, 0 where unknown: the bar then reads the
  /// response's own length.
  int get bytes;

  ModelFacts get facts;

  /// A line on what it is good for, where the catalogue says one.
  String? get note;

  bool get multilingual;

  /// Fetch it, reporting as it goes; cancelling the subscription cancels the
  /// download and leaves nothing behind.
  Stream<DownloadProgress> install();

  Future<void> delete();
}
