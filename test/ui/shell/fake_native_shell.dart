import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_test/flutter_test.dart";

import "native_shell.g.dart";

/// The Swift, as far as a test needs it: the last snapshot of each concern
/// the app sent, and every one of a concern in order where a test counts
/// them. Installed on the test messenger, so what it holds came over the
/// real channels and the contract's codec, decoded on the far side.
class FakeNativeShell implements TestNativeShell {
  FakeNativeShell._();

  /// Answer the app's calls until the test ends.
  static FakeNativeShell install() {
    final shell = FakeNativeShell._();
    TestNativeShell.setUp(shell);
    addTearDown(() => TestNativeShell.setUp(null));
    return shell;
  }

  /// Every snapshot by concern, oldest first.
  final Map<String, List<Object>> sent = {};

  /// The microphone's levels, in order.
  final List<double> levels = [];

  /// Each strip asked for, and what the next is answered with.
  final List<ChoiceStrip> strips = [];
  int? stripAnswer;

  T? _last<T>(String concern) => sent[concern]?.last as T?;

  WindowSnapshot? get lastWindow => _last("window");
  SidebarSnapshot? get lastSidebar => _last("sidebar");
  TitleBarSnapshot? get lastChatBar => _last("chatBar");
  TitleBarSnapshot? get lastPageBar => _last("pageBar");
  ComposerSnapshot? get lastComposer => _last("composer");
  ComposerValueSnapshot? get lastComposerValue => _last("composerValue");
  TurnSnapshot? get lastTurn => _last("turn");
  NewChatSnapshot? get lastNewChat => _last("newChat");
  VoiceSnapshot? get lastVoice => _last("voice");
  PaletteSnapshot? get lastPalette => _last("palette");

  void _add(String concern, Object snapshot) =>
      (sent[concern] ??= []).add(snapshot);

  @override
  void start() {}

  @override
  void window(WindowSnapshot snapshot) => _add("window", snapshot);

  @override
  void sidebar(SidebarSnapshot snapshot) => _add("sidebar", snapshot);

  @override
  void chatBar(TitleBarSnapshot snapshot) => _add("chatBar", snapshot);

  @override
  void pageBar(TitleBarSnapshot snapshot) => _add("pageBar", snapshot);

  @override
  void composer(ComposerSnapshot snapshot) => _add("composer", snapshot);

  @override
  void composerValue(ComposerValueSnapshot snapshot) =>
      _add("composerValue", snapshot);

  @override
  void turn(TurnSnapshot snapshot) => _add("turn", snapshot);

  @override
  void newChat(NewChatSnapshot snapshot) => _add("newChat", snapshot);

  @override
  void voice(VoiceSnapshot snapshot) => _add("voice", snapshot);

  @override
  void palette(PaletteSnapshot snapshot) => _add("palette", snapshot);

  @override
  void voiceLevel(double level) => levels.add(level);

  @override
  void focusComposer() => _add("focusComposer", true);

  @override
  Future<int?> strip(ChoiceStrip request) async {
    strips.add(request);
    return stripAnswer;
  }
}
