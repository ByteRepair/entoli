import "package:flutter_web_plugins/flutter_web_plugins.dart";

/// The two members the real package is reached through. [registerWith] is what
/// the generated plugin registrant calls; [loadWasm] is what `initBindingsAsync`
/// would call, and nothing on the web ever gets that far — `Voice.available` is
/// false there, so the button that would start a session is never drawn.
class SherpaOnnxWeb {
  static void registerWith(Registrar registrar) {}

  static Future<void> loadWasm() async => throw UnsupportedError(
        "Entoli's web build ships no sherpa-onnx WebAssembly. See issue #58.",
      );
}
