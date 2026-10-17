/// Non-web platforms don't need a web artifact opener — they use `file://`
/// paths or a local HTTP server directly. This stub lets the conditional
/// import resolve on every platform without carrying `package:web` into a
/// native build. The name matches the web implementation so the conditional
/// import resolves to one symbol on either platform.
class WebArtifactOpenerImpl {
  const WebArtifactOpenerImpl([_]);
  Future<void> open(String chatId, String artifactId, {required String entryFile}) async {}
}