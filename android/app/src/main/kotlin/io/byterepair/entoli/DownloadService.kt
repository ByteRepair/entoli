<<<<<<<< HEAD:android/app/src/main/kotlin/io/github/yiannis128/agentchat/DownloadService.kt
package io.github.yiannis128.agentchat
========
package io.byterepair.entoli
>>>>>>>> origin/master:android/app/src/main/kotlin/io/byterepair/entoli/DownloadService.kt

import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo

// A voice model being fetched. The only one of the three whose wording comes
// from Dart: which model is being downloaded is the catalog's, and Kotlin has
// never heard of the catalog.
class DownloadService : ForegroundWork() {
    override val job = "download"
    override val channelId = "downloads"
    override val channelLabel = "Downloads"
    override val notificationId = 3
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC

    override fun describe(intent: Intent, builder: Notification.Builder) {
        val label = intent.getStringExtra(EXTRA_LABEL) ?: "voice model"
        val received = intent.getLongExtra(EXTRA_RECEIVED, 0)
        val total = intent.getLongExtra(EXTRA_TOTAL, 0)
        builder.setContentText("Downloading $label")
        // Kilobytes, because the bar takes an Int and a 358 MB model is more
        // bytes than one holds. Indeterminate where the size is not known yet,
        // which is a bar that says "something is happening" rather than one
        // that says "nothing is".
        if (total > 0) {
            builder.setProgress((total / 1024).toInt(), (received / 1024).toInt(), false)
        } else {
            builder.setProgress(0, 0, true)
        }
    }

    companion object {
        const val EXTRA_LABEL = "label"
        const val EXTRA_RECEIVED = "received"
        const val EXTRA_TOTAL = "total"
    }
}
