package io.github.yiannis128.agent_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import io.flutter.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Says the process is busy while a turn is running, so Android does not kill
// it, and gives the user something to see and stop without opening the app.
// The turn itself stays in the Flutter isolate — see "Staying alive off screen"
// in CLAUDE.md.
class AgentService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Dart aborts the turns and the emptied count stops this service,
            // so the notification goes when the work does rather than when the
            // button is pressed. With no channel there is nobody to ask.
            channel?.invokeMethod("stopRequested", null) ?: stopSelf()
            return START_NOT_STICKY
        }

        val turns = intent?.getIntExtra(EXTRA_TURNS, 1) ?: 1
        try {
            val notification = notification(turns)
            // Service types arrived in Android 10; below it the manifest's is
            // ignored and there is only the two-argument call.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Refusing is allowed — most likely the daily cap below has already
            // been spent — and an uncaught refusal here is a crash.
            Log.w(TAG, "Foreground service refused: $e")
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        // Not START_STICKY: a restart would have no turns to keep alive, since
        // they died with the process.
        return START_NOT_STICKY
    }

    // Android 15 caps a dataSync service at six hours a day and crashes the app
    // if it does not stop promptly once told. The turn is left running: the
    // process is merely killable again.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "Foreground service timed out; the process is killable again.")
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    // A foreground service is not kept awake: the device still suspends with
    // the screen off, which stalls the turn's own sockets and timers. The
    // timeout is a backstop against leaking the lock, and a turn still running
    // when it expires only becomes suspendable — the same outcome as onTimeout.
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:turn").apply {
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun notification(turns: Int): Notification {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Running turns", NotificationManager.IMPORTANCE_LOW)
        )

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText(if (turns == 1) "Running a turn" else "Running $turns turns")
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

        // What Android 16 puts in the status bar chip if it promotes this.
        // There is no API to ask for the chip, only to say what it would read.
        if (Build.VERSION.SDK_INT >= 36) builder.setShortCriticalText(turns.toString())
        return builder.build()
    }

    private fun pendingStop() = PendingIntent.getService(
        this,
        0,
        Intent(this, AgentService::class.java).setAction(ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    companion object {
        private const val TAG = "AgentService"
        private const val CHANNEL_ID = "turns"
        private const val NOTIFICATION_ID = 1
        private const val EXTRA_TURNS = "turns"
        private const val ACTION_STOP = "io.github.yiannis128.agent_chat.STOP"
        private const val WAKE_LOCK_TIMEOUT_MS = 6L * 60 * 60 * 1000

        // Static because the service has to reach the channel and is not what
        // registered it. There is one engine per process and it is cached for
        // the life of it, so there is nothing here to keep in step.
        private var channel: MethodChannel? = null

        // Whether the isolate has work the process must not be killed for.
        // MainActivity reads it to decide whether to keep the engine.
        var busy = false
            private set

        fun register(context: Context, messenger: BinaryMessenger) {
            val appContext = context.applicationContext
            channel = MethodChannel(messenger, "agent_chat/background").apply {
                setMethodCallHandler { call, result ->
                    if (call.method != "running") return@setMethodCallHandler result.notImplemented()
                    setTurns(appContext, call.arguments as? Int ?: 0)
                    result.success(null)
                }
            }
        }

        // Only ever called from a running turn, which only starts from a tap: a
        // backgrounded app may not start a foreground service at all, so this
        // must not wait until the app is off screen to ask.
        private fun setTurns(context: Context, turns: Int) {
            busy = turns > 0
            val intent = Intent(context, AgentService::class.java)
            if (!busy) {
                context.stopService(intent)
                return
            }
            context.startForegroundService(intent.putExtra(EXTRA_TURNS, turns))
        }
    }
}
