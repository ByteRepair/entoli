package io.byterepair.entoli

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
        val appContext = context.applicationContext
        val code = intent.getIntExtra(EXTRA_CODE, -1)
        val id = triggerIdFor(appContext, code) ?: run {
            Log.w(TAG, "No trigger holds request code $code; alarm dropped")
            return
        }
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

    // The alarm carries only its request code, the one thing Dart arms with;
    // the trigger it belongs to is whatever `reminders.json` says holds it now.
    private fun triggerIdFor(context: Context, code: Int): String? {
        if (code < 0) return null
        return try {
            val reminders = readReminders(context) ?: return null
            (0 until reminders.length())
                .map { reminders.getJSONObject(it) }
                .firstOrNull { it.optInt("requestCode", -1) == code }
                ?.optString("id")
                ?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read reminders for code $code: $e")
            null
        }
    }

    companion object {
        private const val TAG = "ReminderReceiver"
        const val ACTION_FIRE = "io.byterepair.entoli.FIRE_REMINDER"
        const val EXTRA_CODE = "reminder_code"
    }
}
