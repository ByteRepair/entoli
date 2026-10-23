package io.byterepair.entoli

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// The copy with formatting, which Flutter's own clipboard call cannot make:
// it writes plain text only. See rich_clipboard.dart.
object ClipboardChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/clipboard").setMethodCallHandler { call, result ->
            if (call.method != "setHtml") return@setMethodCallHandler result.notImplemented()
            val plain = call.argument<String>("plain")
            val html = call.argument<String>("html")
            if (plain == null || html == null) {
                return@setMethodCallHandler result.error("bad-args", "plain and html", null)
            }
            val clipboard = appContext.getSystemService(ClipboardManager::class.java)
            clipboard.setPrimaryClip(ClipData.newHtmlText("Entoli", plain, html))
            result.success(null)
        }
    }
}
