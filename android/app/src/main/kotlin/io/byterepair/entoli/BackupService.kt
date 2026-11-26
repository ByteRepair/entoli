package io.byterepair.entoli

import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo

// A backup being written or restored. No button: cut off part-way, a backup
// is a broken file and a restore a broken data directory.
class BackupService : ForegroundWork() {
    override val job = "backup"
    override val channelId = "backup"
    override val channelLabel = "Backups"
    override val notificationId = 7
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    override val actionLabel: String? = null

    override fun describe(intent: Intent, builder: Notification.Builder) {
        builder.setContentText("Backing up")
    }
}
