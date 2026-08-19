import "assistant_launch.dart";

/// The assistant gesture on a platform that has none. Nothing ever arrives,
/// which is what leaves the launch handler inert everywhere but Android — the
/// same answer `UnavailableShell` and `UnavailableWebSearch` give.
class UnavailableAssistantLaunch implements AssistantLaunch {
  const UnavailableAssistantLaunch();

  @override
  Future<bool> take() async => false;

  @override
  Stream<void> get launched => const Stream<void>.empty();
}
