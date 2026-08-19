package io.github.yiannis128.agent_chat

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Where the bundled tools were extracted to. Only the platform knows: the path
// carries an install-specific segment, so it changes with every app update and
// cannot be composed from the package name. See "Bundled tools" in CLAUDE.md
// for why they live there at all.
object ToolsChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/tools").setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeLibraryDir" -> result.success(appContext.applicationInfo.nativeLibraryDir)
                else -> result.notImplemented()
            }
        }
    }
}
