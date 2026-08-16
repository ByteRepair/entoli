package io.github.yiannis128.agent_chat

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The launcher entries, and the whitelist an icon name is checked against.
    // MainActivity is the default icon's own entry — it wears the app-level
    // android:icon — and the rest are activity-aliases.
    private val entries = listOf("MainActivity", "CookieIcon")

    private val declaredIn = MainActivity::class.java.name.substringBeforeLast('.')

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agent_chat/app_icon")
            .setMethodCallHandler { call, result ->
                if (call.method != "use") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val wanted = call.arguments as? String
                if (wanted == null || wanted !in entries) {
                    result.error("unknown_icon", "No icon named $wanted", null)
                    return@setMethodCallHandler
                }
                // Enable before disabling: an instant with no launcher entry
                // enabled takes the app off the home screen for good, and two
                // enabled at once shows it twice.
                setState(wanted, enabled = true)
                entries.filter { it != wanted }.forEach { setState(it, enabled = false) }
                result.success(null)
            }
    }

    // The class half is namespace-relative, since that is what the manifest
    // merger expanded `.CookieIcon` against; the package half is the id the app
    // is installed under, which a debug applicationIdSuffix makes a different
    // string.
    private fun setState(entry: String, enabled: Boolean) = packageManager.setComponentEnabledSetting(
        ComponentName(packageName, "$declaredIn.$entry"),
        if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
        PackageManager.DONT_KILL_APP,
    )
}
