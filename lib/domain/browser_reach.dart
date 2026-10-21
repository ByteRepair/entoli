/// What a page in a browser needs from an endpoint before it can call it. A
/// browser sends every request with the page's origin and drops any answer the
/// server did not mark as readable by it (CORS), so an endpoint a desktop
/// reaches without a word can be one a browser never gets an answer from. Most
/// hosted providers allow every origin; these are the ones the presets name
/// that do not, and what to do about each.
library;

/// Ollama's own port. Its server answers only the origins it was told to,
/// localhost's among them, and a page served from anywhere else is refused.
const ollamaPort = 11434;

/// Where Ollama Cloud is served. It answers no browser at all.
const ollamaCloudHost = "ollama.com";

bool _isLoopback(String host) =>
    host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1";

/// Whether [baseUrl] is an Ollama server on this machine.
bool isLocalOllama(Uri baseUrl) =>
    _isLoopback(baseUrl.host) && baseUrl.port == ollamaPort;

/// The sentence a browser user needs about [baseUrl] before it will answer a
/// page from [origin], or null where nothing is known to stand in the way.
String? browserReachNote(Uri baseUrl, {required String origin}) {
  if (baseUrl.host == ollamaCloudHost) {
    return "Ollama Cloud does not answer requests from a browser. Run Ollama "
        "on this computer instead: once signed in (ollama signin), it serves "
        "the cloud models too, under their :cloud names.";
  }
  if (isLocalOllama(baseUrl)) {
    final page = Uri.tryParse(origin);
    // Ollama allows its own machine's origins unasked.
    if (page != null && _isLoopback(page.host)) return null;
    return "Ollama answers this page only once it allows its origin. Start it "
        "with OLLAMA_ORIGINS=$origin set, e.g. "
        "OLLAMA_ORIGINS=$origin ollama serve.";
  }
  return null;
}

/// Why a request from a browser to [url] got no answer at all. A browser says
/// nothing more than that the fetch failed, whether the server is down or
/// refused the page's origin, so the reason has to name both.
String browserUnreachable(Uri url, {required String origin}) {
  final note = browserReachNote(url, origin: origin);
  return "The browser could not reach $url: the server is not running, or it "
      "does not accept requests from this page ($origin)."
      "${note == null ? "" : " $note"}";
}
