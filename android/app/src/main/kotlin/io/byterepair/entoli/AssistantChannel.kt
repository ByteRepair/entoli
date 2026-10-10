<<<<<<<< HEAD:android/app/src/main/kotlin/io/github/yiannis128/agentchat/AssistantChannel.kt
package io.github.yiannis128.agentchat
========
package io.byterepair.entoli
>>>>>>>> origin/master:android/app/src/main/kotlin/io/byterepair/entoli/AssistantChannel.kt

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// The system's assistant gesture, reaching Dart. Registered as an assistant in
// the manifest, Entoli is launched with ACTION_ASSIST; all Dart needs is that
// it happened, since which project and which view a launch opens are settings.
// See "Assistant registration" in CLAUDE.md.
//
// Held rather than pushed, for the reason FilesChannel holds a staged share:
// the gesture is usually what starts the app, and Dart is not listening for a
// good while after that. So a launch waits in `pending` until Dart asks, and
// the invoke is only a nudge for the app that was already up.
//
// Registered on the engine against the application context, like every other
// channel here: the engine outlives the activity.
object AssistantChannel {
    private var channel: MethodChannel? = null

    private var pending = false

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "agent_chat/assistant").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeLaunch" -> result.success(pending.also { pending = false })
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun receive(intent: Intent?) {
        if (intent?.action != Intent.ACTION_ASSIST) return
        // Consumed, so an activity recreated from the same intent does not open
        // a second chat.
        intent.action = Intent.ACTION_MAIN
        pending = true
        channel?.invokeMethod("assist", null)
    }
}
