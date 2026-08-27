package io.github.yiannis128.agentchat

import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo

// The on-device model's system prompt being warmed. Like a download, its
// wording comes from Dart — which model is being prefilled is the catalog's.
// Unlike the other three it is meant to be seen: the user set it going and then
// left, so the channel is at the default importance rather than the silent
// LOW the holds that accompany work already on screen keep.
class PrefillService : ForegroundWork() {
    override val job = "prefill"
    override val channelId = "prefill"
    override val channelLabel = "Prefilling"
    override val notificationId = 4
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    override val importance = NotificationManager.IMPORTANCE_DEFAULT

    override fun describe(intent: Intent, builder: Notification.Builder) {
        val model = intent.getStringExtra(EXTRA_MODEL) ?: "a model"
        builder.setContentText("Prefilling $model so the first chat starts sooner")
        // Indeterminate: Dart reports which model, not how far. A bar that says
        // "something is happening" is the honest one when the fraction is not
        // sent.
        builder.setProgress(0, 0, true)
    }

    companion object {
        const val EXTRA_MODEL = "model"
    }
}
