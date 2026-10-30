package io.byterepair.entoli

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

// The workspace explorer's way out of the app and back in: ACTION_VIEW to open
// a file, the share sheet to send a selection anywhere, and ACTION_SEND from
// another app to bring one in. See "The workspace explorer" in AGENTS.md.
//
// Everything handed out is a copy under cacheDir, because a FileProvider only
// mints URIs under the paths in res/xml/file_paths.xml and one cache directory
// is the whole of that file. Dart stages those copies; this end only wraps them
// in intents.
//
// Registered on the engine against the application context, like IconChannel
// and for the same reason: the engine outlives the activity, so a handler
// closing over one would hold a destroyed activity for the life of the process.
// FLAG_ACTIVITY_NEW_TASK is what an app context needs to start anything, and
// the chooser wants it anyway.
object FilesChannel {
    private var channel: MethodChannel? = null

    // Staged and waiting for Dart to say which workspace they belong in. Held
    // rather than pushed, because a share can be what launched the app and Dart
    // is not listening for a good while after that.
    private val pending = mutableListOf<Staged>()

    private data class Staged(val name: String, val file: File)

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        channel = MethodChannel(messenger, "agent_chat/files").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> result.wrap { open(appContext, call) }
                    "share" -> result.wrap { share(appContext, call) }
                    "takeShare" -> result.success(take(appContext))
                    else -> result.notImplemented()
                }
            }
        }
    }

    // Copy whatever an ACTION_SEND intent carries into the cache. Right away
    // and not on demand: the read permission on those URIs is granted to the
    // activity's task and dies with it, and the user takes a while to pick a
    // workspace.
    fun receive(context: Context, intent: Intent?) {
        if (intent == null) return
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.stream())
            Intent.ACTION_SEND_MULTIPLE -> intent.streams()
            else -> return
        }
        // Consumed, so an activity recreated from the same intent does not
        // stage the share a second time.
        intent.action = Intent.ACTION_MAIN
        if (uris.isEmpty()) return
        val appContext = context.applicationContext
        // Off the main thread: a large share would otherwise freeze the launch.
        copier.execute {
            val dir = incomingDir(appContext).apply { mkdirs() }
            val staged = uris.mapNotNull { uri -> stage(appContext, uri, dir) }
            if (staged.isEmpty()) return@execute
            synchronized(pending) { pending += staged }
            main.post { channel?.invokeMethod("shared", null) }
        }
    }

    // One thread, so shares stage in the order they arrived and `take`'s prune
    // never runs under a copy still being written.
    private val copier = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private fun stage(context: Context, uri: Uri, dir: File): Staged? = try {
        val name = displayName(context, uri)
        // Prefixed, so two shares of the same filename do not land on each
        // other while both are waiting to be claimed.
        val file = File(dir, "${System.nanoTime()}-$name")
        context.contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { output -> input.copyTo(output) }
            Staged(name, file)
        }
    } catch (e: Exception) {
        Log.w(TAG, "Shared file not read: $e")
        null
    }

    // Pruned here rather than on the way in, because Dart now holds the staged
    // copies until a workspace is picked instead of reading them at once: a
    // second share arriving while that page is open would otherwise delete the
    // paths the page is still pointing at. Anything left over at this moment is
    // an earlier batch nobody claimed, since only one is ever offered at a
    // time — see `IncomingShares`.
    private fun take(context: Context): List<Map<String, String>> {
        val taken = synchronized(pending) { pending.toList().also { pending.clear() } }
        copier.execute {
            val keep = (taken + synchronized(pending) { pending.toList() }).map { it.file }.toSet()
            incomingDir(context).listFiles()?.forEach { if (it !in keep) it.deleteRecursively() }
        }
        return taken.map { mapOf("path" to it.name, "file" to it.file.absolutePath) }
    }

    private fun open(context: Context, call: MethodCall) {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uriFor(context, call.argument<String>("path")!!), call.mime())
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        // No chooser here, unlike `share`: opening a file should go where the
        // user's default already goes.
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw IllegalStateException("Nothing on this device opens that file", e)
        }
    }

    private fun share(context: Context, call: MethodCall) {
        val uris = ArrayList(call.argument<List<String>>("paths")!!.map { uriFor(context, it) })
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        // createChooser rather than letting a default app win: the point of the
        // button is that every app on the device is on offer.
        context.startActivity(
            Intent.createChooser(
                intent.setType(call.mime()).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "Share",
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    private fun MethodCall.mime() = argument<String>("mime") ?: "*/*"

    // The authority is ${applicationId}.files, so it follows the debug
    // applicationIdSuffix the way IconChannel's ComponentName has to.
    private fun incomingDir(context: Context) = File(context.cacheDir, "incoming")

    private fun uriFor(context: Context, path: String): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.files", File(path))

    // Another app wrote this, a share or a clip, so it is trimmed to a single
    // segment here and sanitised again in Dart before it is joined onto a
    // workspace.
    fun displayName(context: Context, uri: Uri): String {
        val name = context.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?: uri.lastPathSegment
        return name?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "file"
    }

    @Suppress("DEPRECATION")
    private fun Intent.stream(): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun Intent.streams(): List<Uri> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
        } else {
            getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        }

    // A refusal reaches Dart, which puts it on the page. Uncaught it would be a
    // crash, and a share sheet that will not open is not worth one.
    private fun MethodChannel.Result.wrap(body: () -> Unit) = try {
        body()
        success(null)
    } catch (e: Exception) {
        error("files", e.message, null)
    }

    private const val TAG = "FilesChannel"
}
