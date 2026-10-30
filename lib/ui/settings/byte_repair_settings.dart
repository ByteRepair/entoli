import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/local/byte_repair_store.dart";
import "../../domain/builtin_project.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../widgets/destructive_button.dart";
import "../widgets/section_header.dart";
import "../widgets/settings_warning_banner.dart";

/// The Byte Repair category: whether the configured terminal env can run its
/// tooling, a button that installs it, a button to import a local ESBMC
/// binary, a button to delete the whole environment, and the versions found
/// afterwards.
///
/// The setup runs only where it can: a rootfs env picked from the Terminal
/// settings on Android, the host shell with a bin directory to install into
/// on the desktops — the store's [ByteRepairStore.capabilityBanner] answers
/// where the platform's facts live, so this page neither guesses at a
/// platform nor names a store's internals. Where it cannot run, the category
/// says so and hides the buttons, which could only report their own refusal;
/// the delete stays, the data being real wherever the tooling is not, with
/// its confirm message the store's
/// [ByteRepairStore.deleteConfirmMessage]. Where it can run, what it does to
/// the machine outside the app is said above the buttons
/// ([ByteRepairStore.setupNotice]), and a prerequisite only the user can
/// install is a command to paste into a terminal, drawn as a reply's code
/// block is so it carries the same copy button.
class ByteRepairSection extends ConsumerStatefulWidget {
  const ByteRepairSection({super.key});

  @override
  ConsumerState<ByteRepairSection> createState() => _ByteRepairSectionState();
}

class _ByteRepairSectionState extends ConsumerState<ByteRepairSection> {
  bool _running = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = ref.watch(byteRepairStoreProvider);
    final banner = store.capabilityBanner;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Byte Repair",
          description:
              "Installs ESBMC and supporting tooling for formal "
              "verification of C code. Runs through the configured terminal "
              "environment, so it needs one with a package manager.",
        ),
        if (banner != null)
          SettingsWarningBanner(
            icon: Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            text: banner,
          )
        else ...[
          if (store.setupNotice case final notice?)
            SettingsWarningBanner(
              icon: Icons.info_outline,
              color: theme.colorScheme.onSurfaceVariant,
              text: notice,
            ),
          if (store.prerequisite case (:final why, :final command)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(why, style: theme.textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DecoratedBox(
                decoration: codeBlockDecoration(theme),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CodeBlock(code: command, language: "bash"),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _running ? null : _runSetup,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text("Run Setup"),
                ),
                OutlinedButton.icon(
                  onPressed: _running ? null : _importEsbmc,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text("Import ESBMC"),
                ),
              ],
            ),
          ),
          if (_running) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(),
            ),
          ],
          const SizedBox(height: 16),
          _ToolStatusList(),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        DestructiveButton(
          icon: Icons.delete_outline,
          label: "Delete Byte Repair Data",
          confirmTitle: "Delete Byte Repair environment?",
          confirmMessage: store.deleteConfirmMessage,
          onConfirmed: () async {
            // The environment first: it is the half that can fail, and
            // failing before the chats are gone leaves the user something
            // to retry with.
            final error = await ref
                .read(byteRepairStoreProvider)
                .deleteEnvironment();
            if (!mounted) return;
            if (error != null) {
              setState(() => _error = error);
              return;
            }
            final repo = ref.read(chatRepositoryProvider);
            final project = ByteRepairProject().dir;
            final chats = await repo.listChats();
            await Future.wait(
              chats
                  .where((c) => c.project == project)
                  .map((c) => repo.deleteChat(c.id)),
            );
            if (!mounted) return;
            ref.invalidate(byteRepairToolVersionsProvider);
            ref.invalidate(setupCompleteProvider(project));
            ref.invalidate(chatListProvider);
          },
        ),
      ],
    );
  }

  /// Runs [work] with the buttons dead; what it returns is the error to show.
  Future<void> _run(Future<String?> Function() work) async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final error = await work();
      if (mounted && error != null) setState(() => _error = error);
    } catch (e) {
      if (mounted) setState(() => _error = "$e");
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runSetup() => _run(() async {
    final result = await ref
        .read(byteRepairStoreProvider)
        .install(ref.read(shellProvider));
    if (result.returnCode != 0) {
      return result.exceptionInfo ?? result.output.trim();
    }
    if (!mounted) return null;
    ref.invalidate(byteRepairToolVersionsProvider);
    ref.invalidate(setupCompleteProvider(ByteRepairProject().dir));
    return null;
  });

  Future<void> _importEsbmc() => _run(() async {
    const type = XTypeGroup(label: "ESBMC binary");
    final file = await openFile(acceptedTypeGroups: const [type]);
    if (file == null) return null;
    final error = await ref.read(byteRepairStoreProvider).importEsbmc(file);
    if (error == null && mounted) {
      ref.invalidate(byteRepairToolVersionsProvider);
    }
    return error;
  });
}

class _ToolStatusList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(byteRepairToolVersionsProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: versions.when(
        loading: () => const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (e, st) => mutedParagraph(context, "Not installed"),
        data: (map) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tool in ByteRepairStore.tools.keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 72,
                      child: Text(tool, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      child: Text(
                        map[tool] ?? "Not installed",
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: map[tool] != null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
