package io.github.yiannis128.agent_chat

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// The colour the system is themed to, which Dart seeds the palette with when
// Material 3 Expressive is on. accent1_500 is the tone Android derives its own
// palette from, and it only exists from 12 — an older phone answers null,
// which is what takes the switch off the settings page.
//
// Registered against the application context for the reason IconChannel is:
// the engine outlives the activity.
object ThemeChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/palette").setMethodCallHandler { call, result ->
            if (call.method != "accent") return@setMethodCallHandler result.notImplemented()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                return@setMethodCallHandler result.success(null)
            }
            result.success(appContext.getColor(android.R.color.system_accent1_500))
        }
    }
}
