package io.github.yiannis128.agent_chat

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val aliases = listOf("CookieIcon")

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
                when (wanted) {
                    null -> result.error("unknown_icon", "No icon named null", null)
                    // The default icon is what MainActivity itself wears via the
                    // app-level android:icon, so selecting it means restoring
                    // MainActivity as the launcher entry and dropping any alias.
                    "MainActivity" -> {
                        resetIcon()
                        result.success(null)
                    }
                    in aliases -> {
                        // Enable before disabling: an instant with no launcher
                        // entry enabled takes the app off the home screen for
                        // good. The alias and MainActivity are mutually
                        // exclusive — both enabled at once shows the app twice
                        // — so the alias goes on first, then MainActivity off.
                        enable(wanted)
                        disableSelf()
                        result.success(null)
                    }
                    else -> result.error("unknown_icon", "No icon named $wanted", null)
                }
            }
    }

    private fun resetIcon() {
        aliases.forEach(::disable)
        packageManager.setComponentEnabledSetting(
            ComponentName(declaredIn, MainActivity::class.java.name),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
    }

    private fun enable(alias: String) = setState(alias, PackageManager.COMPONENT_ENABLED_STATE_ENABLED)

    private fun disable(alias: String) = setState(alias, PackageManager.COMPONENT_ENABLED_STATE_DISABLED)

    private fun disableSelf() = packageManager.setComponentEnabledSetting(
        ComponentName(declaredIn, MainActivity::class.java.name),
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
        PackageManager.DONT_KILL_APP,
    )

    // The package is the namespace, not the applicationId: a debug
    // applicationIdSuffix makes the two diverge, and the alias names in the
    // manifest are relative to the namespace.
    private fun setState(alias: String, state: Int) = packageManager.setComponentEnabledSetting(
        ComponentName(declaredIn, "$declaredIn.$alias"),
        state,
        PackageManager.DONT_KILL_APP,
    )
}
