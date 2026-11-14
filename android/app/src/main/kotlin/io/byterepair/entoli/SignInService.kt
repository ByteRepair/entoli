package io.byterepair.entoli

import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo

// A CLI's sign-in waiting on its page, which is open in another app. Frozen
// meanwhile, the process leaves the program's localhost callback unanswered
// and the page loads forever. The account's name rides in from Dart.
class SignInService : ForegroundWork() {
    override val job = "signIn"
    override val channelId = "signIn"
    override val channelLabel = "Signing in"
    override val notificationId = 6
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC

    override fun describe(intent: Intent, builder: Notification.Builder) {
        val plan = intent.getStringExtra(EXTRA_PLAN) ?: "your account"
        builder.setContentText("Waiting for you to sign in to $plan")
    }

    companion object {
        const val EXTRA_PLAN = "plan"
    }
}
