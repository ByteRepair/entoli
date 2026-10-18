package io.byterepair.entoli

import android.content.Context
import android.os.Process
import android.system.Os
import android.system.OsConstants
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
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
        release()
    }

    /// Throw the cached engine away, so the next launch runs `main` afresh.
    /// The process lives on, so what it decided about attachment goes too.
    fun release() {
        everAttached = false
        val cache = FlutterEngineCache.getInstance()
        val engine = cache.get(ID) ?: return
        cache.remove(ID)
        killChildren()
        engine.destroy()
    }

    // What Dart started with Process.start — a model server, a persistent
    // shell — outlives the isolate, and the process with it; nothing on this
    // platform stops them on the way out. Only direct children: their own
    // die with them or are reparented, and are not ours to find.
    private fun killChildren() {
        val me = Process.myPid()
        File("/proc").listFiles()?.forEach { dir ->
            val pid = dir.name.toIntOrNull() ?: return@forEach
            try {
                // `pid (comm) state ppid ...`; comm may hold spaces and parens.
                val stat = File(dir, "stat").readText()
                val ppid = stat.substringAfterLast(')').trim().split(' ')[1].toInt()
                if (ppid == me) Os.kill(pid, OsConstants.SIGKILL)
            } catch (e: Exception) {
                // Gone between the listing and the read, or not ours to signal.
            }
        }
    }
}
