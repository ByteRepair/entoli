import "dart:convert";
import "dart:math";

import "../../core/config.dart";
import "../../domain/documents.dart" show RenameWriter;
import "../../domain/reminder.dart";

/// The user's reminders, one JSON list at `<dataDir>/reminders.json`. Read at
/// startup, written whole on every change — the list is small and there is no
/// log to append to.
///
/// Writes go through a rename like every other document: the boot receiver
/// reads this file with no engine running, so a read landing mid-write must
/// never find a half-written one.
class FileReminderStore {
  FileReminderStore(this._config) : _write = RenameWriter.fs(_config.fs);

  final AppConfig _config;
  final RenameWriter _write;

  Future<List<Reminder>> load() async {
    try {
      final text = await _config.fs.file(_config.remindersFile).readAsString();
      final list = jsonDecode(text) as List<dynamic>;
      return [
        for (final entry in list)
          if (entry is Map<String, dynamic>) Reminder.fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<Reminder> reminders) => _write.write(
      _config.remindersFile, jsonEncode([for (final r in reminders) r.toJson()]));
}

/// A small int unique among the reminders on disk, for the alarm PendingIntent.
/// Assigned once at creation and kept for the reminder's life; derived codes
/// would collide occasionally and a collision silently overwrites another
/// reminder's alarm.
int nextRequestCode(List<Reminder> reminders) => reminders.isEmpty
    ? 1
    : reminders.map((r) => r.requestCode ?? 0).reduce(max) + 1;
