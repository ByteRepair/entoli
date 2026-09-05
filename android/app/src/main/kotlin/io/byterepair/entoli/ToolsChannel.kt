<<<<<<<< HEAD:android/app/src/main/kotlin/io/github/yiannis128/agentchat/ToolsChannel.kt
package io.github.yiannis128.agentchat
========
package io.byterepair.entoli
>>>>>>>> origin/master:android/app/src/main/kotlin/io/byterepair/entoli/ToolsChannel.kt

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

// Where the bundled tools were extracted to, and which architecture they are
// for. Only the platform knows either: the path carries an install-specific
// segment, so it changes with every app update and cannot be composed from the
// package name, and the ABI decides which rootfs a download has to fetch. See
// "Bundled tools" in CLAUDE.md for why they live there at all.
object ToolsChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, "agent_chat/tools").setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeLibraryDir" -> result.success(appContext.applicationInfo.nativeLibraryDir)
                // The first is the one the app was installed for: a 64-bit
                // device lists its 32-bit ABIs after it, and a guest of the
                // wrong word size is not something to download by accident.
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
                "dnsServers" -> result.success(dnsServers(appContext))
                else -> result.notImplemented()
            }
        }
    }

    // What the network this device is on resolves names with. A Linux in app
    // storage has no other way to find out: Android answers through its own
    // resolver rather than through /etc/resolv.conf, which is the file every
    // guest program reads. Asking means the user's own DNS — their VPN, their
    // private DNS, their network's — is what the guest uses, instead of a
    // public resolver picked here on their behalf.
    private fun dnsServers(context: Context): List<String> {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return emptyList()
        val network = manager.activeNetwork ?: return emptyList()
        val properties = manager.getLinkProperties(network) ?: return emptyList()
        return properties.dnsServers.mapNotNull { it.hostAddress }
    }
}
