import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/builtin_project.dart";
import "package:entoli_core/model/file_picker.dart";

import "../providers.dart";
import "live_log.dart";

/// Whether setup, an import or a delete is running, and what went wrong with
/// the last. What it printed is [ByteRepairRun.log].
typedef SetupRun = ({bool running, String? error});

final byteRepairRunProvider = NotifierProvider<ByteRepairRun, SetupRun>(
  ByteRepairRun.new,
);

/// The Byte Repair tooling's setup, import and delete, one at a time.
class ByteRepairRun extends Notifier<SetupRun> {
  @override
  SetupRun build() {
    ref.onDispose(log.dispose);
    return (running: false, error: null);
  }

  /// What the last run printed, kept until the next one starts.
  final log = LiveLog();

  /// Runs the bundled install script through the configured env.
  Future<void> setUp() => _run(() async {
    final store = ref.read(byteRepairStoreProvider);
    final background = ref.read(backgroundWorkProvider);
    unawaited(background.settingUp(true));
    final result = await store
        .install(ref.read(shellProvider), onOutput: log.replace)
        .whenComplete(() => unawaited(background.settingUp(false)));
    // The whole of it: the live view may hold only part.
    if (result.output.isNotEmpty) log.replace(result.output);
    if (result.returnCode != 0) {
      return result.exceptionInfo ?? result.output.trim();
    }
    _refresh();
    return null;
  });

  /// Puts [file], a local ESBMC binary, where setup would have.
  Future<void> importEsbmc(PickedFile file) => _run(() async {
    final error = await ref.read(byteRepairStoreProvider).importEsbmc(file);
    if (error == null && ref.mounted) {
      ref.invalidate(byteRepairToolVersionsProvider);
    }
    return error;
  });

  /// The environment and then every chat in the project. The environment
  /// first: it is the half that can fail, and failing before the chats are
  /// gone leaves something to retry with.
  Future<void> delete() => _run(() async {
    final store = ref.read(byteRepairStoreProvider);
    final error = await store.deleteEnvironment(log: log);
    if (error != null) return error;
    final repo = ref.read(chatRepositoryProvider);
    final project = ByteRepairProject().dir;
    final chats = (await repo.listChats())
        .where((chat) => chat.project == project)
        .toList();
    log.writeln("Deleting ${chats.length} chats in the project");
    await Future.wait(chats.map((chat) => repo.deleteChat(chat.id)));
    log.writeln("Done");
    if (ref.mounted) _refresh();
    return null;
  });

  /// What setup changes, re-asked once it has.
  void _refresh() {
    ref.invalidate(byteRepairToolVersionsProvider);
    ref.invalidate(setupCompleteProvider(ByteRepairProject().dir));
  }

  /// [work] with the buttons dead and [log] cleared for it; what it returns
  /// is the error to show.
  Future<void> _run(Future<String?> Function() work) async {
    if (state.running) return;
    state = (running: true, error: null);
    log.clear();
    String? error;
    try {
      error = await work();
    } catch (e) {
      error = "$e";
    }
    if (error != null) log.writeln(error);
    if (ref.mounted) state = (running: false, error: error);
  }
}
