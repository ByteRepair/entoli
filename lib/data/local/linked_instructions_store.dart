import "dart:convert";
import "dart:io";

import "../../core/config.dart";
import "../../core/log.dart" show logFailure;
import "../../domain/documents.dart" show RenameWriter;
import "../../domain/linked_instructions.dart";

/// [LinkedInstructions] at `<dataDir>/instruction_files.json`. Read by every
/// turn and written by two pages, the profile's list and a project's
/// switches, so a change is a read, an edit and a write in one queue: two
/// pages saving at once would otherwise each write back what the other had
/// not seen.
class LinkedInstructionsStore {
  LinkedInstructionsStore(this._config) : _write = RenameWriter();

  final AppConfig _config;
  final RenameWriter _write;
  Future<void> _queue = Future.value();

  Future<LinkedInstructions> load() async {
    try {
      final file = File(_config.linkedInstructionsFile);
      if (!file.existsSync()) return const LinkedInstructions();
      return LinkedInstructions.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      logFailure("instructions", "the linked instruction files could not be read", e);
      return const LinkedInstructions();
    }
  }

  Future<void> update(LinkedInstructions Function(LinkedInstructions) change) {
    final next = _queue.then((_) async {
      final current = await load();
      final updated = change(current);
      // Most project deletions touch nothing here, and on a phone the file
      // would otherwise be made only to say so.
      if (identical(updated, current)) return;
      await _write.write(
          _config.linkedInstructionsFile, jsonEncode(updated.toJson()));
    });
    _queue = next.catchError((_) {});
    return next;
  }
}
