import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_test/flutter_test.dart";

import "native_transcript.g.dart";

/// The Swift end of the transcript, as far as a test needs it: every
/// snapshot the app sent, oldest first, over the real channel and codec.
class FakeNativeTranscript implements TestNativeTranscript {
  FakeNativeTranscript._();

  static FakeNativeTranscript install() {
    final native = FakeNativeTranscript._();
    TestNativeTranscript.setUp(native);
    addTearDown(() => TestNativeTranscript.setUp(null));
    return native;
  }

  final conversations = <ConversationSnapshot>[];
  final details = <DetailSnapshot>[];
  final pictures = <FormulaPicture>[];

  /// Every row as the client holds it: the last of each key sent.
  Map<String, RowSnapshot> get rows => {
    for (final c in conversations)
      for (final row in c.changed) row.key: row,
  };

  @override
  void conversation(ConversationSnapshot snapshot) =>
      conversations.add(snapshot);

  @override
  void formulas(List<FormulaPicture> pictures) =>
      this.pictures.addAll(pictures);

  @override
  void detail(DetailSnapshot snapshot) => details.add(snapshot);
}
