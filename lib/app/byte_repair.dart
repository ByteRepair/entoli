import "dart:async";

import "package:file_selector/file_selector.dart" show XFile;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/builtin_project.dart";
import "../providers.dart";

/// Whether setup or an import is running, what went wrong with the last, and
/// what the last setup printed.
typedef SetupRun = ({bool running, String? error, String? log});

final byteRepairRunProvider = NotifierProvider<ByteRepairRun, SetupRun>(
  ByteRepairRun.new,
);

/// The Byte Repair tooling's setup, import and delete, one at a time.
class ByteRepairRun extends Notifier<SetupRun> {
  @override
  SetupRun build() => (running: false, error: null, log: null);

  /// Runs the bundled install script through the configured env.
  Future<void> setUp() => _run((log) async {
    final store = ref.read(byteRepairStoreProvider);
    final background = ref.read(backgroundWorkProvider);
    unawaited(background.settingUp(true));
    final result = await store
        .install(ref.read(shellProvider), onOutput: log)
        .whenComplete(() => unawaited(background.settingUp(false)));
    // The whole of it: the live view may hold only part.
    if (result.output.isNotEmpty) log(result.output);
    if (result.returnCode != 0) {
      return result.exceptionInfo ?? result.output.trim();
    }
    _refresh();
    return null;
  });

  /// Puts [file], a local ESBMC binary, where setup would have.
  Future<void> importEsbmc(XFile file) => _run((_) async {
    final error = await ref.read(byteRepairStoreProvider).importEsbmc(file);
    if (error == null && ref.mounted) {
      ref.invalidate(byteRepairToolVersionsProvider);
    }
    return error;
  });

  /// The environment and then every chat in the project. The environment
  /// first: it is the half that can fail, and failing before the chats are
  /// gone leaves something to retry with.
  Future<void> delete() => _run((_) async {
    final error = await ref.read(byteRepairStoreProvider).deleteEnvironment();
    if (error != null) return error;
    final repo = ref.read(chatRepositoryProvider);
    final project = ByteRepairProject().dir;
    final chats = await repo.listChats();
    await Future.wait(
      chats
          .where((chat) => chat.project == project)
          .map((chat) => repo.deleteChat(chat.id)),
    );
    if (ref.mounted) _refresh();
    return null;
  });

  /// What setup changes, re-asked once it has.
  void _refresh() {
    ref.invalidate(byteRepairToolVersionsProvider);
    ref.invalidate(setupCompleteProvider(ByteRepairProject().dir));
  }

  /// [work] with the buttons dead; what it returns is the error to show. It
  /// reports the output so far through the callback it is handed.
  Future<void> _run(
    Future<String?> Function(void Function(String log) log) work,
  ) async {
    if (state.running) return;
    state = (running: true, error: null, log: null);
    void log(String text) {
      if (ref.mounted) state = (running: true, error: null, log: text);
    }

    String? error;
    try {
      error = await work(log);
    } catch (e) {
      error = "$e";
    }
    if (ref.mounted) state = (running: false, error: error, log: state.log);
  }
}
