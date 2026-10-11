// The TLS trust the app's network calls are made under. This is the app's
// second conditional import (the first is platform.dart's), split the same way
// the http package splits its own client: the io side reads the OS's root
// store and carries the fallback below; a browser trusts what it bundles and
// has nothing to fall back from.
export "tls/trust_io.dart" if (dart.library.js_interop) "tls/trust_web.dart";