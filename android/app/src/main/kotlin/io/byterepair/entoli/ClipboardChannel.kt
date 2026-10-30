package io.byterepair.entoli

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

// The copy with formatting, which Flutter's own clipboard call cannot make:
// it writes plain text only. And the files a paste brings, which it cannot
// read. See rich_clipboard.dart and clipboard_files.dart.
object ClipboardChannel {
    private val reads = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/clipboard").setMethodCallHandler { call, result ->
            val clipboard = appContext.getSystemService(ClipboardManager::class.java)
            when (call.method) {
                "setHtml" -> {
                    val plain = call.argument<String>("plain")
                    val html = call.argument<String>("html")
                    if (plain == null || html == null) {
                        return@setMethodCallHandler result.error("bad-args", "plain and html", null)
                    }
                    clipboard.setPrimaryClip(ClipData.newHtmlText("Entoli", plain, html))
                    result.success(null)
                }
                "readFiles" -> {
                    // A text clip has no URIs, so it answers nothing and the
                    // field pastes it.
                    val uris = clipboard.primaryClip?.let { clip ->
                        (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
                    }.orEmpty()
                    if (uris.isEmpty()) return@setMethodCallHandler result.success(emptyList<Any>())
                    reads.execute {
                        val files = uris.mapNotNull { read(appContext, it) }
                        main.post { result.success(files) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun read(context: Context, uri: Uri): Map<String, Any>? = try {
        val resolver = context.contentResolver
        resolver.openInputStream(uri)?.use { it.readBytes() }?.let { bytes ->
            buildMap {
                put("name", FilesChannel.displayName(context, uri))
                put("bytes", bytes)
                resolver.getType(uri)?.let { put("mime", it) }
            }
        }
    } catch (e: Exception) {
        Log.w("clipboard", "pasted file unreadable: ${e.javaClass.simpleName}")
        null
    }
}
