package io.byterepair.entoli

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.Log
import org.json.JSONArray
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId

// After a reboot every alarm is gone, so they are read back out of the same
// file Dart writes and re-armed against the times it already computed. No
// engine is started and no recurrence math runs here: this receiver exists in
// exactly one shape — a list of request codes and epoch millis — which is why
// `reminders.json` carries `nextFireAt` rather than only the anchor.
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED -> {}
            else -> return
        }
        val reminders: JSONArray = try {
            readReminders(context) ?: return
        } catch (e: Exception) {
            Log.w(TAG, "Could not read reminders: $e")
            return
        }
        for (i in 0 until reminders.length()) {
            // Per record, not per file: one record this build cannot parse is
            // one lost alarm, and the rest still re-arm — Dart's catch-up
            // covers the lost one at the next launch.
            try {
                val reminder = reminders.getJSONObject(i)
                val code = reminder.optInt("requestCode", -1)
                val next = reminder.optString("nextFireAt", "")
                if (!reminder.optBoolean("enabled", true) || code < 0 || next.isEmpty()) continue
                // A record a later build wrote may carry an offset (the agent
                // may arm a schedule with one); an instant is an instant.
                val at =
                    if (next.endsWith("Z") || offsetAt(next)) OffsetDateTime.parse(next).toInstant()
                    else LocalDateTime.parse(next).atZone(ZoneId.systemDefault()).toInstant()
                RemindersChannel.schedule(context.applicationContext, code, at.toEpochMilli())
            } catch (e: Exception) {
                Log.w(TAG, "Could not re-arm reminder $i: $e")
            }
        }
    }

    private fun offsetAt(next: String): Boolean {
        val zone = next.takeLast(6)
        return (zone[0] == '+' || zone[0] == '-') && zone[3] == ':'
    }

    companion object {
        private const val TAG = "ReminderBootReceiver"
    }
}
