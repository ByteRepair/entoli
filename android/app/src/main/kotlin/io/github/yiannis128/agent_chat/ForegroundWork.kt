package io.github.yiannis128.agent_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import io.flutter.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Says the process is busy while there is work it must not lose, so Android
// does not kill it, and gives the user something to see and stop without
// opening the app. The work itself stays in the Flutter isolate — see "Staying
// alive off screen" in CLAUDE.md.
//
// Three services rather than one because they are three different things to
// stop, and because Android insists a service that holds the microphone be of
// a different type from one that does not. What they share is all of this: the
// channel, the wake lock, the Stop action and the refusal handling.
abstract class ForegroundWork : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    /// Which Dart `BackgroundJob` this is, and so what Stop reports.
    protected abstract val job: String
    protected abstract val channelId: String
    protected abstract val channelLabel: String
    protected abstract val notificationId: Int
    protected abstract val serviceType: Int

    /// How loud the channel is. Low is a silent hold the user need not notice,
    /// which is what a turn or a download wants. The prefill overrides it: it is
    /// work the user set going and then left, so it is meant to be seen.
    protected open val importance: Int
        get() = NotificationManager.IMPORTANCE_LOW

    /// What the notification says about this piece of work.
    protected abstract fun describe(intent: Intent, builder: Notification.Builder)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Dart stops the work and the emptied hold stops this service, so
            // the notification goes when the work does rather than when the
            // button is pressed. With no channel there is nobody to ask.
            channel?.invokeMethod("stopRequested", job) ?: stopSelf()
            return START_NOT_STICKY
        }

        try {
            val notification = notification(intent ?: Intent())
            // Service types arrived in Android 10; below it the manifest's is
            // ignored and there is only the two-argument call.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(notificationId, notification, serviceType)
            } else {
                startForeground(notificationId, notification)
            }
        } catch (e: Exception) {
            // Refusing is allowed — most likely the daily cap has already been
            // spent, or the microphone permission is not held — and an uncaught
            // refusal here is a crash.
            Log.w(TAG, "Foreground service refused: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        // Not START_STICKY: a restart would have no work to keep alive, since
        // it died with the process.
        return START_NOT_STICKY
    }

    // Android 15 caps a service at six hours a day and crashes the app if it
    // does not stop promptly once told. The work is left running: the process
    // is merely killable again, which is where every other platform already is.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "Foreground service timed out; the process is killable again.")
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    // A foreground service is not kept awake: the device still suspends with
    // the screen off, which stalls the work's own sockets and timers. The
    // timeout is a backstop against leaking the lock, and work still running
    // when it expires only becomes suspendable — the same outcome as onTimeout.
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:$job").apply {
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun notification(intent: Intent): Notification {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(channelId, channelLabel, importance)
        )

        val builder = Notification.Builder(this, channelId)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            // The monochrome adaptive layer: already a silhouette on
            // transparent, which is what a status bar icon has to be, and one
            // fewer copy of path data that has no generator.
            .setSmallIcon(R.drawable.ic_cookie_monochrome)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null as Icon?, "Stop", pendingStop()).build())

        // Whichever launcher entry is enabled: the other one is disabled and
        // cannot be started. See IconChannel.
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            builder.setContentIntent(
                PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
            )
        }

        describe(intent, builder)
        return builder.build()
    }

    private fun pendingStop() = PendingIntent.getService(
        this,
        // Per service: three PendingIntents differing only in their component
        // would otherwise be one, and every Stop would stop the same thing.
        notificationId,
        Intent(this, javaClass).setAction(ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    companion object {
        private const val TAG = "ForegroundWork"
        const val ACTION_STOP = "io.github.yiannis128.agent_chat.STOP"
        private const val WAKE_LOCK_TIMEOUT_MS = 6L * 60 * 60 * 1000

        // Static because a service has to reach the channel and is not what
        // registered it. There is one engine per process and it is cached for
        // the life of it, so there is nothing here to keep in step.
        private var channel: MethodChannel? = null

        private var turns = 0
        private var listening = false
        private var downloading = false
        private var prefilling = false

        // Whether the isolate has work the process must not be killed for.
        // MainActivity reads it to decide whether to keep the engine — voice
        // mode counts, since the session it holds is in that isolate too.
        val busy: Boolean get() = turns > 0 || listening || downloading || prefilling

        fun register(context: Context, messenger: BinaryMessenger) {
            val appContext = context.applicationContext
            channel = MethodChannel(messenger, "agent_chat/background").apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "running" -> {
                            turns = call.arguments as? Int ?: 0
                            hold(appContext, AgentService::class.java, turns > 0) {
                                it.putExtra(AgentService.EXTRA_TURNS, turns)
                            }
                        }
                        "listening" -> {
                            listening = call.arguments as? Boolean ?: false
                            hold(appContext, VoiceService::class.java, listening)
                        }
                        "downloading" -> {
                            @Suppress("UNCHECKED_CAST")
                            val notice = call.arguments as? Map<String, Any?>
                            downloading = notice != null
                            hold(appContext, DownloadService::class.java, downloading) {
                                it.putExtra(DownloadService.EXTRA_LABEL, notice?.get("label") as? String)
                                it.putExtra(DownloadService.EXTRA_RECEIVED, (notice?.get("received") as? Number)?.toLong() ?: 0L)
                                it.putExtra(DownloadService.EXTRA_TOTAL, (notice?.get("total") as? Number)?.toLong() ?: 0L)
                            }
                        }
                        "prefilling" -> {
                            val model = call.arguments as? String
                            prefilling = model != null
                            hold(appContext, PrefillService::class.java, prefilling) {
                                it.putExtra(PrefillService.EXTRA_MODEL, model)
                            }
                        }
                        else -> return@setMethodCallHandler result.notImplemented()
                    }
                    result.success(null)
                }
            }
        }

        // Only ever called from work that starts with a tap: a backgrounded app
        // may not start a foreground service at all, so nothing here waits
        // until the app is off screen to ask.
        private fun hold(
            context: Context,
            service: Class<out ForegroundWork>,
            wanted: Boolean,
            describe: (Intent) -> Unit = {},
        ) {
            val intent = Intent(context, service)
            if (!wanted) {
                context.stopService(intent)
                // The last piece of work just ended. If no activity ever
                // attached — the process was woken by an alarm and nobody came
                // — the isolate it built is a full app nobody is looking at
                // and nothing will reattach to except through a launch that
                // must then skip main, which is the restart contract quietly
                // broken. Release it; see AppEngine.
                AppEngine.releaseIfUnwanted()
                return
            }
            describe(intent)
            context.startForegroundService(intent)
        }
    }
}
