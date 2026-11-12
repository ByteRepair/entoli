import "package:agent_chat/ui/shell/shell_chat.dart";
import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart" show settleIo;
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

/// What `ShellBridge` holds for the open chat, around [child]: a
/// [ShellChat] over the app's container, its pages opened over this context.
class ShellChatHost extends StatefulWidget {
  const ShellChatHost({super.key, required this.child});

  final Widget child;

  @override
  State<ShellChatHost> createState() => _ShellChatHostState();
}

class _ShellChatHostState extends State<ShellChatHost> {
  late final ShellChat _chat = ShellChat(
    ProviderScope.containerOf(context, listen: false),
    () => context,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chat;
  }

  @override
  void dispose() {
    _chat.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// [settleIo], then the fake clock moved on: what the open chat publishes
/// comes from provider listeners, which the container tells after the I/O
/// that changed them, on a clock a bare pump does not advance.
Future<void> settleShell(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await settleIo(tester);
    await tester.pump(const Duration(milliseconds: 1));
  }
}
