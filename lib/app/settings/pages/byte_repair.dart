import "package:file_selector/file_selector.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/local/byte_repair_store.dart";
import "../../../domain/builtin_project.dart";
import "../../../providers.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.byteRepair;

/// Whether setup or an import is running, and what went wrong with the last.
typedef SetupRun = ({bool running, String? error});

final byteRepairRunProvider = NotifierProvider<ByteRepairRun, SetupRun>(
  ByteRepairRun.new,
);

class ByteRepairRun extends Notifier<SetupRun> {
  @override
  SetupRun build() => (running: false, error: null);

  /// Runs [work] with the buttons dead; what it returns is the error to show.
  Future<void> run(Future<String?> Function() work) async {
    if (state.running) return;
    state = (running: true, error: null);
    String? error;
    try {
      error = await work();
    } catch (e) {
      error = "$e";
    }
    if (ref.mounted) state = (running: false, error: error);
  }

  void fail(String error) => state = (running: false, error: error);
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
        deleteConfirm: SettingConfirm(
          title: "Delete Byte Repair environment?",
          message: store.deleteConfirmMessage,
          confirmLabel: "Delete",
          destructive: true,
        ),
        setUp: () => runner.run(() async {
          final result = await store.install(shell);
          if (result.returnCode != 0) {
            return result.exceptionInfo ?? result.output.trim();
          }
          refresh();
          return null;
        }),
        import: () => runner.run(() async {
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
