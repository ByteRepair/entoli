package io.github.yiannis128.agent_chat

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val aliases = listOf("PromptIcon", "CookieIcon")

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
                if (wanted == null || wanted !in aliases) {
                    result.error("unknown_icon", "No alias named $wanted", null)
                    return@setMethodCallHandler
                }
                // Enable before disabling: an instant with no alias enabled
                // takes the app off the home screen for good.
                enable(wanted)
                aliases.filter { it != wanted }.forEach(::disable)
                result.success(null)
            }
    }

    private fun enable(alias: String) = setState(alias, PackageManager.COMPONENT_ENABLED_STATE_ENABLED)

    private fun disable(alias: String) = setState(alias, PackageManager.COMPONENT_ENABLED_STATE_DISABLED)

    // DONT_KILL_APP: the default kills the app, and a settings page is waiting.
    private fun setState(alias: String, state: Int) = packageManager.setComponentEnabledSetting(
        ComponentName(packageName, "$declaredIn.$alias"),
        state,
        PackageManager.DONT_KILL_APP,
    )
}
