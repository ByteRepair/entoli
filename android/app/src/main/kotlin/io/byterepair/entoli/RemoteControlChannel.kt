package io.byterepair.entoli

import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// The bridge between Dart and the accessibility service. The service is a
// system component, so this channel only relays: it asks [RemoteControlService]
// for a screenshot or an input event. Registered against the application
// context, like every other channel here.
object RemoteControlChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/remote_control").setMethodCallHandler { call, result ->
            val service = RemoteControlService.instance
            when (call.method) {
                "openSettings" -> {
                    appContext.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "screenshot" -> {
                    val bytes = service?.screenshot()
                    if (bytes == null) result.error("unavailable", "The accessibility service is not connected.", null)
                    else result.success(bytes)
                }
                "click" -> {
                    val x = call.argument<Int>("x") ?: return@setMethodCallHandler result.error("bad_args", "x is required", null)
                    val y = call.argument<Int>("y") ?: return@setMethodCallHandler result.error("bad_args", "y is required", null)
                    val button = call.argument<Int>("button") ?: 1
                    service?.click(x, y, button)
                    result.success(null)
                }
                "key" -> {
                    val text = call.argument<String>("text") ?: return@setMethodCallHandler result.error("bad_args", "text is required", null)
                    service?.key(text)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
