package io.byterepair.entoli

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.os.Build
import android.view.accessibility.AccessibilityEvent
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// The screen the agent can see and drive. A system component the user enables
// in system settings; the app cannot start it, only link to the settings page.
// RemoteControlChannel reaches it through [instance], which is set while the
// service is connected and cleared when it is not.
//
// Screenshots use takeScreenshot (API 30+), which is callback-based; a latch
// turns it synchronous for the channel. Input uses dispatchGesture for taps
// and performGlobalAction for keys. Text is typed one character at a time: a
// key event per rune, since a model typing a string is a sequence of single
// keys.
class RemoteControlService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: RemoteControlService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    fun screenshot(): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val latch = CountDownLatch(1)
        var bitmap: Bitmap? = null
        takeScreenshot(
            android.view.Display.DEFAULT_DISPLAY,
            Executors.newSingleThreadExecutor(),
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    bitmap = Bitmap.wrapHardwareBuffer(
                        screenshot.hardwareBuffer, screenshot.colorSpace)
                    latch.countDown()
                }

                override fun onFailure(errorCode: Int) {
                    latch.countDown()
                }
            },
        )
        if (!latch.await(5, TimeUnit.SECONDS)) return null
        val captured = bitmap ?: return null
        val out = ByteArrayOutputStream()
        captured.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    // A tap at a point. Android's gesture API has no notion of a secondary or
    // tertiary button, so [button] is accepted for parity with the Linux side
    // but every value is a primary tap.
    fun click(x: Int, y: Int, button: Int) {
        val path = android.graphics.Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 100))
            .build()
        dispatchGesture(gesture, null, null)
    }

    fun key(text: String) {
        for (rune in text) {
            val keycode = keycodeFor(rune)
            if (keycode != null) {
                performGlobalAction(keycode)
            }
        }
    }

    private fun keycodeFor(rune: Char): Int? = when (rune) {
        '\n' -> android.view.KeyEvent.KEYCODE_ENTER
        '\t' -> android.view.KeyEvent.KEYCODE_TAB
        ' ' -> android.view.KeyEvent.KEYCODE_SPACE
        else -> {
            val upper = rune.uppercaseChar()
            if (upper in 'A'..'Z') {
                android.view.KeyEvent.KEYCODE_A + (upper - 'A')
            } else if (rune in '0'..'9') {
                android.view.KeyEvent.KEYCODE_0 + (rune - '0')
            } else {
                null
            }
        }
    }
}
