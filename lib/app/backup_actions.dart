import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/formatting.dart";

import "../core/platform/platform.dart" as platform;
import "../data/backup.dart";
import "../providers.dart";

/// Whether a backup is being written or restored, which holds both buttons
/// wherever they are drawn.
final backupBusyProvider = NotifierProvider<BackupBusy, bool>(BackupBusy.new);

/// Everything the app holds, out as one file and back in. The format is
/// `data/backup.dart`'s; this is the two directions, and what is checked
/// before the second goes ahead.
class BackupBusy extends Notifier<bool> {
  @override
  bool build() => false;

  /// [work], unless one is already running.
  Future<T?> run<T>(Future<T> Function() work) async {
    if (state) return null;
    state = true;
    try {
      return await work();
    } finally {
      if (ref.mounted) state = false;
    }
  }

  /// Writes a backup where the user says, and how big it came out; null where
  /// they cancelled.
  Future<int?> export() async {
    final config = ref.read(appConfigProvider);
    var size = 0;
    final saved = await ref.read(backupHandoffProvider).save(
      backupFilename(DateTime.now()),
      (path) async {
        await writeBackup(config, path);
        size = await File(path).length();
      },
    );
    return saved ? size : null;
  }

  /// Why a restore cannot start now, if it cannot. A courtesy rather than a
  /// safeguard: the restart stops a running turn either way.
  String? get refusal =>
      ref.read(agentBackendProvider).runningTurns.value.isEmpty
      ? null
      : "A turn is still running. Stop it first.";

  /// The backup the user picks, opened to say what is in it; null where they
  /// picked nothing. Throws [BackupFormatException] for a file that is not one.
  Future<Backup?> pick() async {
    final path = await ref.read(backupHandoffProvider).pick();
    return path == null ? null : openBackup(path);
  }

  /// Replaces everything with [backup] and starts the app again on it. The
  /// restore runs inside the restart, with no session over the files it
  /// replaces: everything that writes to them belongs to the session.
  Future<void> restore(Backup backup) {
    final config = ref.read(appConfigProvider);
    return ref
        .read(appRestartProvider)
        .restart(
          // The platform's, which gets past proot's mode-0000 stubs an
          // earlier restore left behind, and the read-only skills.
          whileStopped: () =>
              restoreBackup(config, backup, deleteTree: platform.deleteTree),
        );
  }
}

/// What a restore's confirm says about [backup].
String describeBackup(Backup backup, {DateTime? now}) {
  final made = backup.createdAt;
  final when = made == null
      ? "A backup"
      : "A backup from ${formatAge((now ?? DateTime.now()).difference(made))}";
  return "$when, holding ${plural(backup.chats, "chat")} and "
      "${formatSize(backup.size)}.";
}
