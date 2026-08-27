package io.github.yiannis128.agent_chat

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// The sync device name's default: the name the user set in system settings,
// which is `Settings.Global device_name` from Android 7 (API 24). `minSdk` is
// 26, so the setting is always available. `Platform.localHostname` answers
// "localhost" on Android, which is what the default was before this.
//
// Registered against the application context for the reason ThemeChannel is:
// the engine outlives the activity.
object DeviceChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/device").setMethodCallHandler { call, result ->
            if (call.method != "name") return@setMethodCallHandler result.notImplemented()
            val name = Settings.Global.getString(appContext.contentResolver, "device_name")
            result.success(name?.takeIf { it.isNotBlank() } ?: Build.MODEL)
        }
    }
}
