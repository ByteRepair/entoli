<<<<<<<< HEAD:android/app/src/main/kotlin/io/github/yiannis128/agentchat/AppEngine.kt
package io.github.yiannis128.agentchat
========
package io.byterepair.entoli
>>>>>>>> origin/master:android/app/src/main/kotlin/io/byterepair/entoli/AppEngine.kt

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
// The one place the app's engine is built. Every way the process comes to be
// running Dart goes through [ensure] — an activity launch, or an alarm waking
// nothing — so channels and plugins are registered exactly once and both paths
// get an identical engine.
//
// MainActivity hands back whatever [ensure] returns and runs nothing itself;
// the delegate sees Dart already executing and reattaches rather than running
// main again. A reminder receiver calls [runIfIdle], which executes the
// entrypoint headlessly — runApp builds the widget tree with no surface, and
// frames begin when an activity eventually attaches.
object AppEngine {
    const val ID = "agent_chat"

    /// Whether an activity has ever attached in this process. An engine woken
    /// by an alarm has no user anywhere near it; when its work drains and
    /// nobody ever came, ForegroundWork releases it, because a sticky isolate
    /// nobody opened is a restart that never comes — see "Staying alive off
    /// screen".
    @Volatile
    var everAttached = false
        private set

    fun noteActivityAttached() {
        everAttached = true
    }

    fun ensure(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        // Registered against the application context: the engine outlives any
        // activity, and a handler closing over one would hold a destroyed
        // activity for the life of the process.
        IconChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        ThemeChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        DeviceChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        ForegroundWork.register(appContext, engine.dartExecutor.binaryMessenger)
        FilesChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        AssistantChannel.register(engine.dartExecutor.binaryMessenger)
        VoiceChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        ToolsChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        RemindersChannel.register(appContext, engine.dartExecutor.binaryMessenger)
        // Before anything executes: main's first awaited calls hit plugins and
        // channels immediately, and a MissingPluginException at startup is the
        // symptom of getting this order wrong.
        GeneratedPluginRegistrant.registerWith(engine)
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }

    /// Execute `main` where it is not already running. Both callers sit on the
    /// main looper, so this cannot race the activity's own check-and-run.
    fun runIfIdle(context: Context) {
        val engine = ensure(context.applicationContext)
        if (engine.dartExecutor.isExecutingDart) return
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationComplete(context.applicationContext, emptyArray())
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }

    /// Throw the cached engine away while nothing needs it and no activity has
    /// ever attached — the release half of a cold start. One an activity did
    /// attach to belongs to MainActivity.onDestroy's rules instead.
    fun releaseIfUnwanted() {
        if (everAttached || ForegroundWork.busy) return
        val cache = FlutterEngineCache.getInstance()
        val engine = cache.get(ID) ?: return
        cache.remove(ID)
        engine.destroy()
    }
}
