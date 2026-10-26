package io.byterepair.entoli

import android.app.Presentation
import android.content.Context
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// The agent's browser on Android: one WebView per chat, driven from Dart over
// the DevTools Protocol that debugging serves on `@webview_devtools_remote_<pid>`.
// The WebView cannot open a page of its own over the protocol, so this is
// where a chat's page is made, its first address naming the chat for Dart to
// find it by. See "The browser" in lib/data/builtin/AGENTS.md.
object BrowserChannel {
    private val views = mutableMapOf<String, WebView>()

    // The pages are drawn on a display of the app's own that nobody sees: a
    // WebView whose window is not visible stops answering even clicks, and the
    // activity's window is not visible while a turn runs with the app in the
    // background. The frames go into a reader that throws each one away.
    private class Offscreen(
        val reader: ImageReader,
        val display: VirtualDisplay,
        val presentation: Presentation,
        val frame: FrameLayout,
    )

    private var offscreen: Offscreen? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/browser").setMethodCallHandler { call, result ->
            when (call.method) {
                // Only while the browser runs: any app with adb's shell can
                // reach the socket debugging opens.
                "start" -> {
                    WebView.setWebContentsDebuggingEnabled(true)
                    result.success(null)
                }
                "open" -> {
                    val chat = call.argument<String>("chat")
                        ?: return@setMethodCallHandler result.error("bad-args", "chat", null)
                    open(appContext, chat)
                    result.success(null)
                }
                "close" -> {
                    close()
                    result.success(null)
                }
                "clearData" -> {
                    CookieManager.getInstance().removeAllCookies(null)
                    WebStorage.getInstance().deleteAllData()
                    WebView(appContext).apply { clearCache(true) }.destroy()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Dart asks only for a page it has lost, so a view still here for the
    // chat is stale and is replaced rather than found by its first address.
    private fun open(context: Context, chat: String) {
        val frame = (offscreen ?: show(context).also { offscreen = it }).frame
        views.remove(chat)?.let {
            frame.removeView(it)
            it.destroy()
        }
        val view = WebView(frame.context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
        }
        views[chat] = view
        frame.addView(view, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        view.loadUrl("about:blank?entoli=$chat")
    }

    // The phone's own screen size, so a page lays out as it would for the user.
    private fun show(context: Context): Offscreen {
        val metrics = context.resources.displayMetrics
        val reader = ImageReader.newInstance(
            metrics.widthPixels, metrics.heightPixels, PixelFormat.RGBA_8888, 2)
        reader.setOnImageAvailableListener(
            { it.acquireLatestImage()?.close() }, Handler(Looper.getMainLooper()))
        val display = context.getSystemService(DisplayManager::class.java).createVirtualDisplay(
            "entoli-browser", metrics.widthPixels, metrics.heightPixels,
            metrics.densityDpi, reader.surface, 0)
        val presentation = Presentation(context, display.display)
        val frame = FrameLayout(presentation.context)
        presentation.setContentView(frame)
        presentation.show()
        return Offscreen(reader, display, presentation, frame)
    }

    private fun close() {
        views.values.forEach { it.destroy() }
        views.clear()
        offscreen?.run {
            presentation.dismiss()
            display.release()
            reader.close()
        }
        offscreen = null
        WebView.setWebContentsDebuggingEnabled(false)
    }
}
