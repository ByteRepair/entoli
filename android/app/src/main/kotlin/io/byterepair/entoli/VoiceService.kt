<<<<<<<< HEAD:android/app/src/main/kotlin/io/github/yiannis128/agentchat/VoiceService.kt
package io.github.yiannis128.agentchat
========
package io.byterepair.entoli
>>>>>>>> origin/master:android/app/src/main/kotlin/io/byterepair/entoli/VoiceService.kt

import android.app.Notification
import android.content.Intent
import android.content.pm.ServiceInfo

// Voice mode. A type of its own rather than dataSync beside the turns: from
// Android 14 a service that holds the microphone has to say so, hold
// RECORD_AUDIO, and be started while the app is in use — all three of which
// hold here, since voice mode only ever starts from a tap.
//
// Its Stop leaves voice mode and leaves a running turn alone. That is not an
// oversight: the turn has a Stop of its own, and stopping the wrong one is
// worse than pressing twice.
class VoiceService : ForegroundWork() {
    override val job = "voice"
    override val channelId = "voice"
    override val channelLabel = "Voice mode"
    override val notificationId = 2
    override val serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE

    override fun describe(intent: Intent, builder: Notification.Builder) {
        builder.setContentText("Voice mode is running")
    }
}
