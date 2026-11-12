import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/formatting.dart";
import "../../../core/platform/platform.dart" as platform;
import "../../../data/backup.dart";
import "../../../providers.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.data;

/// Whether a backup is being written or restored, which holds both buttons.
final backupBusyProvider = NotifierProvider<BackupBusy, bool>(BackupBusy.new);

class BackupBusy extends Notifier<bool> {
  @override
  bool build() => false;

  /// [work], unless one is already running.
  Future<SettingNotice?> run(Future<SettingNotice?> Function() work) async {
    if (state) return null;
    state = true;
    try {
      return await work();
    } catch (e) {
      return SettingNotice("$e");
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

const dataSections = [
  SectionSpec(
    page: _page,
    id: "backup",
    title: "Backup",
    weight: 0,
    description:
        "Every chat, project, workspace, prompt and setting as "
        "one zip. Restoring one replaces what is here.",
  ),
];

String _describe(Backup backup) {
  final made = backup.createdAt;
  final when = made == null
      ? "A backup"
      : "A backup from ${formatAge(DateTime.now().difference(made))}";
  return "$when, holding ${plural(backup.chats, "chat")} and "
      "${formatSize(backup.size)}.";
}

final dataSettings = [
  // Everything the app holds, out as one file and back in. The format is
  // `data/backup.dart`'s; this is the two buttons, and what the second has to
  // ask before it goes ahead.
  SettingSpec(
    id: "backup",
    path: (page: _page, section: "backup"),
    weight: 0,
    title: "Backup",
    hint: UiHint.buttons,
    build: (c) {
      final busy = c.ref.watch(backupBusyProvider);
      final runner = c.ref.read(backupBusyProvider.notifier);
      final handoff = c.ref.read(backupHandoffProvider);
      final config = c.ref.read(appConfigProvider);
      final backend = c.ref.read(agentBackendProvider);
      final restart = c.ref.read(appRestartProvider);
      Backup? opened;
      return GroupController(
        c.spec,
        busy: busy,
        children: [
          ActionController(
            c
                .part(
                  "export",
                  "Export",
                  hint: UiHint.button,
                  glyph: SettingGlyph.download,
                )
                .spec,
            label: "Export",
            enabled: !busy,
            run: () => runner.run(() async {
              var size = 0;
              final saved = await handoff.save(backupFilename(DateTime.now()), (
                path,
              ) async {
                await writeBackup(config, path);
                size = await File(path).length();
              });
              return saved
                  ? SettingNotice("Backup written — ${formatSize(size)}.")
                  : null;
            }),
          ),
          ActionController(
            c
                .part(
                  "import",
                  "Import",
                  hint: UiHint.button,
                  glyph: SettingGlyph.upload,
                )
                .spec,
            label: "Import",
            secondary: true,
            enabled: !busy,
            // Picking and opening the file come first, since what is asked
            // names what is in it. A running turn is a courtesy rather than a
            // safeguard: the restart stops it either way.
            confirm: () async {
              opened = null;
              if (backend.runningTurns.value.isNotEmpty) {
                return const SettingConfirm.note(
                  "A turn is still running. Stop it first.",
                );
              }
              final path = await handoff.pick();
              if (path == null) return const SettingConfirm.nothing();
              try {
                opened = await openBackup(path);
              } on BackupFormatException catch (e) {
                return SettingConfirm.note("That file cannot be restored: $e.");
              }
              return SettingConfirm(
                title: "Restore this backup?",
                message:
                    "${_describe(opened!)}\n\nEverything here now — every "
                    "chat, project, workspace and setting — is replaced by "
                    "what is in it, and Entoli starts again on what was "
                    "restored.",
                confirmLabel: "Restore",
                destructive: true,
              );
            },
            // The restore runs inside the restart, with no session over the
            // files it replaces: everything that writes to them belongs to
            // the session.
            run: () {
              final backup = opened;
              if (backup == null) return Future.value();
              return runner.run(() async {
                await restart.restart(
                  // The platform's, which gets past proot's mode-0000 stubs an
                  // earlier restore left behind, and the read-only skills.
                  whileStopped: () => restoreBackup(
                    config,
                    backup,
                    deleteTree: platform.deleteTree,
                  ),
                );
                return null;
              });
            },
          ),
        ],
      );
    },
  ),
];
