package io.github.yiannis128.agentchat

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Which launcher entry the app shows. MainActivity is the default icon's own
// entry — it wears the app-level android:icon — and the rest are
// activity-aliases, disabled in the manifest and enabled in its place.
//
// Registered on the engine against the application context rather than on each
// attach against the activity: the engine outlives the activity now, so a
// handler closing over one would hold a destroyed activity for as long as the
// process.
object IconChannel {
    private val entries = listOf("MainActivity", "PromptIcon")

    private val declaredIn = MainActivity::class.java.name.substringBeforeLast('.')

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/app_icon").setMethodCallHandler { call, result ->
            if (call.method != "use") return@setMethodCallHandler result.notImplemented()
            val wanted = call.arguments as? String
            if (wanted == null || wanted !in entries) {
                return@setMethodCallHandler result.error("unknown_icon", "No icon named $wanted", null)
            }
            // Enable before disabling: an instant with no launcher entry
            // enabled takes the app off the home screen for good, and two
            // enabled at once shows it twice.
            setState(appContext, wanted, enabled = true)
            entries.filter { it != wanted }.forEach { setState(appContext, it, enabled = false) }
            result.success(null)
        }
    }

    // The class half is namespace-relative, since that is what the manifest
    // merger expanded `.PromptIcon` against; the package half has to be
    // packageName, the id the app is installed under, which a debug
    // applicationIdSuffix makes a different string.
    private fun setState(context: Context, entry: String, enabled: Boolean) =
        context.packageManager.setComponentEnabledSetting(
            ComponentName(context.packageName, "$declaredIn.$entry"),
            if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
}
