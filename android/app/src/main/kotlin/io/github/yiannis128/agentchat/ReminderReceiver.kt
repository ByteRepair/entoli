package io.github.yiannis128.agentchat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.Log

// An alarm went off. Kotlin does not know what the reminder is and never
// runs it: it stashes the id for Dart to claim, holds the process so the
// isolate has time to answer, and starts Dart if nothing was running.
//
// The service is started HERE, synchronously, rather than waiting for Dart's
// TurnKeepAlive: an exact alarm puts the process on a short allowlist during
// which a foreground service may start from the background at all, and
// Dart's first channel round trip may fall outside it. A refusal is caught
// because an uncaught one is a crash — the turn then runs merely killable,
// which is where every other platform already is.
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_FIRE) return
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val appContext = context.applicationContext
        RemindersChannel.receiveFire(appContext, id)
        try {
            appContext.startForegroundService(
                Intent(appContext, AgentService::class.java)
                    .putExtra(AgentService.EXTRA_TURNS, 1),
            )
            // What this started is a hold like any other and ForegroundWork has
            // to count it: `busy` is what stops the engine being thrown away
            // under a turn that has not registered itself yet. Dart releases it
            // once the fire is dealt with, through `doneFiring`.
            ForegroundWork.holdForAlarm()
        } catch (e: Exception) {
            Log.w(TAG, "Could not hold the process for reminder $id: $e")
        }
        AppEngine.runIfIdle(appContext)
    }

    companion object {
        private const val TAG = "ReminderReceiver"
        const val ACTION_FIRE = "io.github.yiannis128.agentchat.FIRE_REMINDER"
        const val EXTRA_ID = "reminder_id"
    }
}
