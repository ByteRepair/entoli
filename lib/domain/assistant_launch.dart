/// The system's assistant gesture (long-press home, or a swipe up from the
/// corner), reaching Entoli. Android's, and only Android's: the stream never
/// fires and [take] never answers true elsewhere, but the port is built on
/// every platform the way `Shell` and `WebSearch` are, so nothing downstream
/// asks what it is running on.
///
/// A launch carries no payload — the gesture is a "start a new chat" signal,
/// and which project and which view that lands in are settings. See
/// `ui/assistant/incoming_assistant.dart` for what opens, and issue #54.
///
/// Two routes in, the shape [FileHandoff] already has for a share, and for the
/// same reason: the gesture can be what starts the app, in which case Kotlin
/// notices it long before Dart is listening.
abstract interface class AssistantLaunch {
  /// Whether a launch is waiting, and taking it if so. Read once on the first
  /// frame, for the gesture that started the app.
  Future<bool> take();

  /// A launch arriving while the app is already up — including into an activity
  /// whose engine was cached and whose `main` therefore does not run again.
  Stream<void> get launched;
}
