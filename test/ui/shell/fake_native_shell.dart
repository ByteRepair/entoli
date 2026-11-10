import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_test/flutter_test.dart";

import "native_shell.g.dart";

/// The Swift, as far as a test needs it: every snapshot the app sent, by
/// concern and oldest first, having come over the real channels and codec.
class FakeNativeShell implements TestNativeShell {
  FakeNativeShell._();

  static FakeNativeShell install() {
    final shell = FakeNativeShell._();
    TestNativeShell.setUp(shell);
    addTearDown(() {
      TestNativeShell.setUp(null);
      return shell._arrivals.close();
    });
    return shell;
  }

  final Map<String, List<Object>> sent = {};
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
  List<double> get levels => [...?sent["voiceLevel"]?.cast<double>()];

  final _arrivals = StreamController<(String, Object)>.broadcast(sync: true);

  /// The next [concern] snapshot that [matches], however it arrives: with no
  /// frame pumped, which is how a snapshot sent off a listener lands.
  Future<T> next<T>(String concern, bool Function(T) matches) => _arrivals
      .stream
      .where((e) => e.$1 == concern && matches(e.$2 as T))
      .map((e) => e.$2 as T)
      .first;

  void _add(String concern, Object value) {
    (sent[concern] ??= []).add(value);
    _arrivals.add((concern, value));
  }

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
  void voiceLevel(double level) => _add("voiceLevel", level);
  @override
  void focusComposer() => _add("focusComposer", true);
  @override
  Future<int?> strip(ChoiceStrip request) async {
    strips.add(request);
    return stripAnswer;
  }
}
