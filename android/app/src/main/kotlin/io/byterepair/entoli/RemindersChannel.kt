package io.byterepair.entoli

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Reminders on the system's clock. Dart owns everything about what a reminder
// is and when it next fires — this end only arms AlarmManager against times it
// is handed, posts the completion notification, and holds what arrived while
// nobody was listening.
//
// Held rather than pushed, like every channel that can be the reason the
// process exists: an alarm may start it, so a fired reminder waits in
// [pendingFired] until Dart asks, and the invoke behind [fired] is only a
// nudge for an isolate that was already up.
object RemindersChannel {
    private const val TAG = "RemindersChannel"
    private const val CHANNEL_ID = "reminders"

    private var channel: MethodChannel? = null

    private val pendingFired = mutableListOf<String>()
    private var pendingOpenChat: String? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        channel = MethodChannel(messenger, "agent_chat/reminders").apply {
            setMethodCallHandler { call, result ->
                try {
                    handle(appContext, call, result)
                } catch (e: Exception) {
                    // A throw in a handler reaches Dart as a platform error;
                    // answering explicitly keeps the failure named.
                    result.error("reminders", "$e", null)
                }
            }
        }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "schedule" -> {
                val code = call.argument<Number>("code")!!.toInt()
                schedule(context, code, call.argument<Number>("at")!!.toLong())
                result.success(null)
            }
            "cancel" -> {
                cancel(context, call.argument<Number>("code")!!.toInt())
                result.success(null)
            }
            "canHoldTurn" -> result.success(canHoldTurn())
            "doneFiring" -> {
                ForegroundWork.releaseAlarmHold(context)
                result.success(null)
            }
            "exactAllowed" -> result.success(exactAllowed(context))
            "requestExact" -> {
                requestExact(context)
                result.success(null)
            }
            "notificationsAllowed" -> result.success(notificationsAllowed(context))
            "requestNotifications" -> {
                requestNotifications(context)
                result.success(null)
            }
            "notify" -> {
                postNotification(context, call)
                result.success(null)
            }
            "takeFired" -> {
                val taken = pendingFired.toList()
                pendingFired.clear()
                result.success(taken)
            }
            "takeOpenChat" -> result.success(pendingOpenChat.also { pendingOpenChat = null })
            else -> result.notImplemented()
        }
    }

    /// Exact where permitted, else inexact, which may fire minutes late under
    /// Doze. Asked per schedule rather than cached: the user grants the
    /// permission while we are up. The boot receiver re-arms through this too.
    internal fun schedule(context: Context, code: Int, atMs: Long) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val pending = fireIntent(context, code)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarms.canScheduleExactAlarms()) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        } else {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        }
    }

    private fun cancel(context: Context, code: Int) {
        context.getSystemService(AlarmManager::class.java)
            .cancel(fireIntent(context, code))
    }

    // The same intent shape every time for one code, or cancel would miss what
    // schedule armed. FLAG_IMMUTABLE because Android 12 insists, UPDATE_CURRENT
    // because re-arming replaces rather than piles up. The code rides as an
    // extra too, since the request code itself never reaches the receiver;
    // extras are not part of a PendingIntent's identity.
    private fun fireIntent(context: Context, code: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            code,
            Intent(context, ReminderReceiver::class.java)
                .setAction(ReminderReceiver.ACTION_FIRE)
                .putExtra(ReminderReceiver.EXTRA_CODE, code),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /// Whether a turn started right now could hold the process. A backgrounded
    /// app may not start a foreground service at all — so a reminder's timer
    /// firing off screen would run a turn nothing keeps alive, and Android
    /// kills the process halfway through it. Already holding one is the other
    /// yes: a receiver's hold, or another turn's, is a service that is already
    /// up and may be started again.
    private fun canHoldTurn(): Boolean {
        if (ForegroundWork.busy) return true
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        // Lower is nearer the user; foreground is the one importance that is
        // allowed to start a service of its own accord.
        return state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    private fun exactAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    private fun requestExact(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        context.startActivity(
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    private fun notificationsAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /// Open the system's notification settings for this app. A settings page
    /// has an activity behind it but this object does not hold one, and a cold
    /// start never has one at all — the indirection is what makes both work.
    private fun requestNotifications(context: Context) {
        val intent = if (Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_SETTINGS)
        }
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun postNotification(context: Context, call: MethodCall) {
        val manager = context.getSystemService(NotificationManager::class.java)
        // Two channels, one port: the reminder completions and a turn failure
        // post through the same method and the same tap route, but a user who
        // wants one half quiet silences a channel, not the other feature.
        val channelId = call.argument<String>("channel") ?: CHANNEL_ID
        val channelName = if (channelId == "turns") "Turn failures" else "Finished reminders"
        manager.createNotificationChannel(
            NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        val chatId = call.argument<String>("chatId")
        val builder = Notification.Builder(context, channelId)
            .setContentTitle(call.argument<String>("title") ?: "Reminder")
            .setContentText(call.argument<String>("body") ?: "")
            .setStyle(Notification.BigTextStyle().bigText(call.argument<String>("body") ?: ""))
            .setSmallIcon(R.drawable.ic_cookie_monochrome)
            .setAutoCancel(true)
        if (chatId != null) {
            // Explicit, at whichever launcher entry is enabled: the other is
            // disabled and cannot be started. See IconChannel.
            val open = Intent().setComponent(IconChannel.enabledEntry(context))
                .putExtra(EXTRA_CHAT_ID, chatId)
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context,
                    chatId.hashCode(),
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        // Clear of the foreground services' ids (1-5), which a post would replace.
        manager.notify(chatId?.hashCode() ?: NO_CHAT_NOTIFICATION_ID, builder.build())
    }

    /// A completion notification was tapped. Called from MainActivity onCreate
    /// and onNewIntent, whichever ran; consumed like the fires are.
    fun receive(context: Context, intent: Intent?) {
        val chatId = intent?.getStringExtra(EXTRA_CHAT_ID) ?: return
        intent.removeExtra(EXTRA_CHAT_ID)
        pendingOpenChat = chatId
        Log.i(TAG, "Open requested for $chatId")
        channel?.invokeMethod("open", chatId)
    }

    internal fun receiveFire(context: Context, id: String) {
        if (!pendingFired.contains(id)) pendingFired.add(id)
        channel?.invokeMethod("fired", null)
    }

    private const val EXTRA_CHAT_ID = "reminder_open_chat"
    private const val NO_CHAT_NOTIFICATION_ID = 1000
}
