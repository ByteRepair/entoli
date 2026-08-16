package io.github.yiannis128.agent_chat

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotifications()
    }

    // Cached, so the isolate outlives this activity and a turn survives the app
    // being swiped off the recents list. Nothing else to override:
    // FlutterActivity already declines to destroy an engine the host provided,
    // and the delegate runs the Dart entrypoint only while Dart is not already
    // executing.
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        IconChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        AgentService.register(appContext, engine.dartExecutor.binaryMessenger)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    // Kept only for as long as something needs it. Cached unconditionally the
    // app would never restart again — `main` would not re-run, so a settings
    // file or a prompt edited behind its back would go on being ignored until
    // Android happened to reclaim the process.
    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing && !isChangingConfigurations && !AgentService.busy) {
            val engine = FlutterEngineCache.getInstance().get(ENGINE_ID)
            FlutterEngineCache.getInstance().remove(ENGINE_ID)
            engine?.destroy()
        }
    }

    // On launch rather than when a turn first needs one: the service is started
    // from a running turn, and by then the user may not be looking at an
    // activity to be asked through. A foreground service whose notification
    // cannot be shown is one nobody can see or stop.
    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
        if (granted == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
    }

    private companion object {
        const val ENGINE_ID = "agent_chat"
    }
}
