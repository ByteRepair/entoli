import "dart:convert";
import "dart:io";
import "dart:math";

import "../../core/config.dart";
import "../../core/log.dart" show logFailure;
import "../../domain/documents.dart" show RenameWriter;
import "../../domain/trigger.dart";

/// The user's triggers, one JSON list at `<dataDir>/reminders.json` — the
/// file the reminder feature wrote, kept where it is because a rename is a
/// migration. Read at startup, written whole on every change — the list is
/// small and there is no log to append to.
///
/// Writes go through a rename like every other document: the boot receiver
/// reads this file with no engine running, so a read landing mid-write must
/// never find a half-written one.
class FileTriggerStore {
  FileTriggerStore(this._config) : _write = RenameWriter();

  final AppConfig _config;
  final RenameWriter _write;

  Future<List<Trigger>> load() async {
    try {
      final file = File(_config.remindersFile);
      if (!file.existsSync()) return const [];
      final text = await file.readAsString();
      final list = jsonDecode(text) as List<dynamic>;
      // Per record, not per file: one entry this build cannot read is one
      // lost trigger, not a list emptied out and written back over its
      // neighbours on the next save.
      final triggers = <Trigger>[];
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          triggers.add(Trigger.fromJson(entry));
        } catch (e) {
          logFailure("triggers", "a stored trigger could not be read", e);
        }
      }
      return triggers;
    } catch (e) {
      logFailure("triggers", "the trigger list could not be read", e);
      return const [];
    }
  }

  Future<void> save(List<Trigger> triggers) => _write.write(_config.remindersFile,
      jsonEncode([for (final t in triggers) t.toJson()]));
}

/// A small int unique among the triggers on disk, for the alarm PendingIntent.
/// Assigned once at creation and kept for the trigger's life; derived codes
/// would collide occasionally and a collision silently overwrites another
/// trigger's alarm. Only the clock kinds use one, but every record carries
/// the slot so codes stay unique without walking which kind wants what.
int nextRequestCode(List<Trigger> triggers) => triggers.isEmpty
    ? 1
    : triggers.map((t) => t.requestCode ?? 0).reduce(max) + 1;