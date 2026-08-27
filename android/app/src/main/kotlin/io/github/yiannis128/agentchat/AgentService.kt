package io.github.yiannis128.agentchat

import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build

// The turns. How a foreground service is held, stopped and refused is all in
// ForegroundWork; this says which one this is and what its notification reads.
class AgentService : ForegroundWork() {
    override val job = "turns"
    override val channelId = "turns"
    override val channelLabel = "Running turns"
    override val notificationId = 1
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC

    override fun describe(intent: Intent, builder: Notification.Builder) {
        val turns = intent.getIntExtra(EXTRA_TURNS, 1)
        builder.setContentText(if (turns == 1) "Running a turn" else "Running $turns turns")
        // What Android 16 puts in the status bar chip if it promotes this.
        // There is no API to ask for the chip, only to say what it would read.
        if (Build.VERSION.SDK_INT >= 36) builder.setShortCriticalText(turns.toString())
    }

    companion object {
        const val EXTRA_TURNS = "turns"
    }
}
