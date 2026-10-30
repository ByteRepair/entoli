import "dart:io";

import "package:path/path.dart" as p;

import "../../domain/local_model.dart";
import "gguf.dart";

/// What a model's files mean once they are on disk: where its runtime is
/// pointed, and the facts read off them. One per engine, handed to the store
/// that keeps that engine's models, so the store itself only fetches and
/// checks files.
abstract class ModelFormat {
  const ModelFormat();

  /// What the runtime loads, inside a model's [directory].
  String entry(String directory);

  /// The record for the model in [directory], read off its own files. [from]
  /// is what it was downloaded as, where that is known. Throws
  /// [FormatException] for files this format cannot run.
  DownloadedModel describe(String id, String directory, [LocalModel? from]);
}

/// One GGUF file, its facts read out of its header.
class GgufFormat extends ModelFormat {
  const GgufFormat();

  @override
  String entry(String directory) => p.join(directory, ggufWeights);

  @override
  DownloadedModel describe(String id, String directory, [LocalModel? from]) {
    final file = entry(directory);
    final facts = readGgufFacts(file);
    return DownloadedModel(
      id: id,
      name: (from?.name.isNotEmpty ?? false ? from!.name : null) ?? facts.name ?? id,
      file: file,
      bytes: File(file).lengthSync(),
      quantisation: facts.quantisation,
      contextLength: facts.contextLength,
      kvBytesPerToken: facts.kvBytesPerToken,
      parameters: from?.parameters,
      licence: from?.licence,
      url: from?.source,
    );
  }
}
