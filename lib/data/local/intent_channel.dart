import "package:flutter/services.dart";

import "../../core/log.dart";
import "../../domain/intent_action.dart";

/// `agent_chat/intents`: where the Apple Runners' App Intents reach an
/// [IntentRegistry]. Swift calls `perform` with an action's id and its
/// arguments, and gets back the action's result or a `refused` error whose
/// message is the sentence Shortcuts shows.
///
/// [listen] says `ready` once the handler is in place. An intent can launch
/// the app, and until Dart is listening a call would find nothing to answer
/// it, so the Swift side holds its calls until it hears this.
class IntentChannel {
  IntentChannel(this._registry);

  static const _channel = MethodChannel("agent_chat/intents");

  final IntentRegistry _registry;

  Future<void> listen() async {
    _channel.setMethodCallHandler(_handle);
    try {
      await _channel.invokeMethod<void>("ready");
    } catch (e) {
      logFailure("intents", "the platform did not hear ready", e);
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != "perform") throw MissingPluginException(call.method);
    final arguments = call.arguments as Map<Object?, Object?>;
    final id = arguments["id"] as String;
    try {
      return await _registry.perform(
        id,
        IntentArgs(arguments["args"] as Map<Object?, Object?>? ?? const {}),
      );
    } on IntentRefused catch (e) {
      throw PlatformException(code: "refused", message: e.reason);
    } catch (e) {
      logFailure("intents", "$id failed", e);
      throw PlatformException(
        code: "failed",
        message: "Entoli could not do that. Its log says why.",
      );
    }
  }
}
