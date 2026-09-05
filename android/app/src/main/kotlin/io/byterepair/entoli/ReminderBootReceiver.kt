<<<<<<<< HEAD:android/app/src/main/kotlin/io/github/yiannis128/agentchat/ReminderBootReceiver.kt
package io.github.yiannis128.agentchat
========
package io.byterepair.entoli
>>>>>>>> origin/master:android/app/src/main/kotlin/io/byterepair/entoli/ReminderBootReceiver.kt

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.Log
import io.flutter.util.PathUtils
import org.json.JSONArray
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId

// After a reboot every alarm is gone, so they are read back out of the same
// file Dart writes and re-armed against the times it already computed. No
// engine is started and no recurrence math runs here: this receiver exists in
// exactly one shape — a list of request codes and epoch millis — which is why
// `reminders.json` carries `nextFireAt` rather than only the anchor.
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIME_CHANGED -> {}
            else -> return
        }
        val file = File(PathUtils.getDataDirectory(context), "agent-chat/reminders.json")
        if (!file.exists()) return
        try {
            val reminders = JSONArray(file.readText())
            for (i in 0 until reminders.length()) {
                val reminder = reminders.getJSONObject(i)
                val code = reminder.optInt("requestCode", -1)
                val next = reminder.optString("nextFireAt", "")
                if (!reminder.optBoolean("enabled", true) || code < 0 || next.isEmpty()) continue
                val at = LocalDateTime.parse(next).atZone(ZoneId.systemDefault())
                RemindersChannel.scheduleAt(context.applicationContext, code, at.toInstant().toEpochMilli())
            }
        } catch (e: Exception) {
            // A file this build cannot parse is left to Dart's catch-up at the
            // next launch; an uncaught throw here would crash on boot.
            Log.w(TAG, "Could not re-arm reminders after boot: $e")
        }
    }

    companion object {
        private const val TAG = "ReminderBootReceiver"
    }
}
