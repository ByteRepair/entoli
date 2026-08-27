package io.github.yiannis128.agentchat

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppEngine.noteActivityAttached()
        requestNotifications()
        FilesChannel.receive(this, intent)
        AssistantChannel.receive(intent)
        RemindersChannel.receive(this, intent)
    }

    // The share or the assistant gesture that arrives while the app is already
    // up. onCreate above is the one that launched it; singleTop is what keeps
    // the two apart.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        FilesChannel.receive(this, intent)
        AssistantChannel.receive(intent)
        RemindersChannel.receive(this, intent)
    }

    // Cached, so the isolate outlives this activity and a turn survives the app
    // being swiped off the recents list — and so an alarm that started the
    // process cold reattaches to its isolate rather than starting a second.
    // Everything about the build is AppEngine.ensure's; nothing else to
    // override. The delegate runs the Dart entrypoint only while Dart is not
    // already executing, so `main` never runs twice.
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        AppEngine.noteActivityAttached()
        return AppEngine.ensure(context)
    }

    // Plugin registration moved into AppEngine.ensure, where every way of
    // building the engine goes through; the default here would register them a
    // second time.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {}

    // Kept only for as long as something needs it. Cached unconditionally the
    // app would never restart again — `main` would not re-run, so a settings
    // file or a prompt edited behind its back would go on being ignored until
    // Android happened to reclaim the process.
    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing && !isChangingConfigurations && !ForegroundWork.busy) {
            val engine = FlutterEngineCache.getInstance().get(AppEngine.ID)
            FlutterEngineCache.getInstance().remove(AppEngine.ID)
            engine?.destroy()
        }
    }

    // On launch rather than when a turn first needs one: the service is started
    // from a running turn, and by then there may be no activity in front of the
    // user to ask through. A foreground service whose notification cannot be
    // shown is one nobody can see or stop.
    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
        if (granted == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
    }
}
