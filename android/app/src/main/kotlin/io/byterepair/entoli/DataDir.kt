package io.byterepair.entoli

import android.content.Context
import io.flutter.util.PathUtils
import org.json.JSONArray
import java.io.File

// The data directory `AppConfig` composes, for the readers that run with no
// engine. The call path_provider's getApplicationDocumentsDirectory makes, so
// this is where `platformDataDir` put it rather than a guess at it.
internal fun appDataDir(context: Context) = File(PathUtils.getDataDirectory(context), "entoli")

// The triggers Dart wrote, or null when there is no file. Throws on a file
// that does not parse; each caller answers that its own way.
internal fun readReminders(context: Context): JSONArray? {
    val file = File(appDataDir(context), "reminders.json")
    if (!file.exists()) return null
    return JSONArray(file.readText())
}
