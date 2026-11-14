import "package:file_selector/file_selector.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/local/byte_repair_store.dart";
import "../../../domain/builtin_project.dart";
import "../../../providers.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.byteRepair;

/// Whether setup or an import is running, what went wrong with the last, and
/// what the last setup printed.
typedef SetupRun = ({bool running, String? error, String? log});

final byteRepairRunProvider = NotifierProvider<ByteRepairRun, SetupRun>(
  ByteRepairRun.new,
);

class ByteRepairRun extends Notifier<SetupRun> {
  @override
  SetupRun build() => (running: false, error: null, log: null);

  /// Runs [work] with the buttons dead; what it returns is the error to show.
  /// [work] reports the output so far through the callback it is handed.
  Future<void> run(
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

  void fail(String error) =>
      state = (running: false, error: error, log: state.log);
}

const byteRepairSections = [
  SectionSpec(
    page: _page,
    id: "byteRepair",
    title: "Byte Repair",
    weight: 0,
    description:
        "Installs ESBMC and supporting tooling for formal "
        "verification of C code. Runs through the configured terminal "
        "environment, so it needs one with a package manager.",
  ),
];

final byteRepairSettings = [
  SettingSpec(
    id: "byteRepair",
    path: (page: _page, section: "byteRepair"),
    weight: 0,
    title: "Byte Repair",
    hint: UiHint.setup,
    build: (c) {
      final store = c.ref.watch(byteRepairStoreProvider);
      final run = c.ref.watch(byteRepairRunProvider);
      final runner = c.ref.read(byteRepairRunProvider.notifier);
      final versions = c.ref.watch(byteRepairToolVersionsProvider);
      final shell = c.ref.read(shellProvider);
      final repo = c.ref.read(chatRepositoryProvider);
      final project = ByteRepairProject().dir;
      // What setup changes, re-asked once it has.
      void refresh() {
        c.ref.invalidate(byteRepairToolVersionsProvider);
        c.ref.invalidate(setupCompleteProvider(project));
      }

      return SetupController(
        c.spec,
        blocked: store.capabilityBanner,
        notice: store.setupNotice,
        prerequisite: store.prerequisite,
        tools: versions.isLoading
            ? null
            : versions.asData?.value ??
                  {for (final tool in ByteRepairStore.tools.keys) tool: null},
        running: run.running,
        error: run.error,
        log: run.log,
        setUpLabel: "Run Setup",
        importLabel: "Import ESBMC",
        deleteLabel: "Delete Byte Repair Data",
        deleteConfirm: SettingConfirm(
          title: "Delete Byte Repair environment?",
          message: store.deleteConfirmMessage,
          confirmLabel: "Delete",
          destructive: true,
        ),
        setUp: () => runner.run((log) async {
          final result = await store.install(shell, onOutput: log);
          // The whole of it: the live view may hold only part.
          if (result.output.isNotEmpty) log(result.output);
          if (result.returnCode != 0) {
            return result.exceptionInfo ?? result.output.trim();
          }
          refresh();
          return null;
        }),
        import: () => runner.run((_) async {
          const type = XTypeGroup(label: "ESBMC binary");
          final file = await openFile(acceptedTypeGroups: const [type]);
          if (file == null) return null;
          final error = await store.importEsbmc(file);
          if (error == null) c.ref.invalidate(byteRepairToolVersionsProvider);
          return error;
        }),
        // The environment first: it is the half that can fail, and failing
        // before the chats are gone leaves something to retry with.
        delete: () async {
          final error = await store.deleteEnvironment();
          if (error != null) return runner.fail(error);
          final chats = await repo.listChats();
          await Future.wait(
            chats
                .where((chat) => chat.project == project)
                .map((chat) => repo.deleteChat(chat.id)),
          );
          refresh();
        },
      );
    },
  ),
];
