package io.byterepair.entoli

import android.app.Notification
import android.app.Notification.Style
import android.content.Intent
import android.content.pm.ServiceInfo

// The paired devices connected while the app is off screen. What keeps a
// WebRTC channel alive through the screen going dark — and dies without it,
// which is why the phone's end of a pair goes quiet in the night. Behind the
// keep-alive setting, since the cost is a wake lock and a persistent
// notification for as long as a connection lasts. The wording counts in
// Kotlin; the names ride in from Dart, the way a download's label does.
class SyncService : ForegroundWork() {
    override val job = "sync"
    override val channelId = "sync"
    override val channelLabel = "Connected devices"
    override val notificationId = 5
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    override val actionLabel = "Disconnect"

    override fun describe(intent: Intent, builder: Notification.Builder) {
        val names = intent.getStringArrayListExtra(EXTRA_NAMES) ?: emptyList()
        builder.setContentText(
            if (names.size == 1) "1 device is connected" else "${names.size} devices are connected"
        )
        // Every name, under the count. BigText rather than one line per device:
        // the count is the line a lock screen shows, the list is what pulling
        // the notification down says.
        if (names.isNotEmpty()) {
            builder.setStyle(Style.BigTextStyle().bigText(names.joinToString("\n")))
        }
    }

    companion object {
        const val EXTRA_NAMES = "names"
    }
}
