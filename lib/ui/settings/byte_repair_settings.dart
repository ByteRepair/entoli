import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/byte_repair.dart";
import "../../data/local/byte_repair_store.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/shell_run.dart" show LiveShellOutput;
import "../widgets/busy.dart";
import "../widgets/destructive_button.dart";
import "../widgets/section_header.dart";
import "../widgets/settings_warning_banner.dart";

/// Settings > Byte Repair: whether the configured terminal env can run its
/// tooling, the command to run first where one is wanted, the setup and
/// import buttons, the tools found, and the delete.
///
/// Where the env cannot run it, the store's banner says so and the buttons
/// are hidden, since they could only report their own refusal; the delete
/// stays, the data being real wherever the tooling is not.
class ByteRepairSettings extends ConsumerWidget {
  const ByteRepairSettings({super.key});

  Future<void> _import(WidgetRef ref) async {
    const type = XTypeGroup(label: "ESBMC binary");
    final file = await openFile(acceptedTypeGroups: const [type]);
    if (file == null) return;
    await ref.read(byteRepairRunProvider.notifier).importEsbmc(file);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final store = ref.watch(byteRepairStoreProvider);
    final run = ref.watch(byteRepairRunProvider);
    final runner = ref.read(byteRepairRunProvider.notifier);
    final blocked = store.capabilityBanner;
    final error = run.error;
    return ListView(
      children: [
        const SectionHeader(
          "Byte Repair",
          description:
              "Installs ESBMC and supporting tooling for formal "
              "verification of C code. Runs through the configured terminal "
              "environment, so it needs one with a package manager.",
        ),
        if (blocked != null)
          SettingsWarningBanner(
            icon: Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            text: blocked,
          )
        else ...[
          if (store.setupNotice case final notice?)
            SettingsWarningBanner(
              icon: Icons.info_outline,
              color: theme.colorScheme.onSurfaceVariant,
              text: notice,
            ),
          // What only the user can install, as a reply's code block so it
          // carries the same copy button.
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
                  onPressed: run.running ? null : runner.setUp,
                  icon: run.running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text("Run Setup"),
                ),
                OutlinedButton.icon(
                  onPressed: run.running
                      ? null
                      : () => guarded(context, () => _import(ref)),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text("Import ESBMC"),
                ),
              ],
            ),
          ),
          if (run.running) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(),
            ),
          ],
          const SizedBox(height: 16),
          const _ToolStatusList(),
          if (run.log case final log? when log.isNotEmpty) _SetupLog(log),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              error,
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
          onConfirmed: () => guarded(context, runner.delete),
          enabled: !run.running,
        ),
      ],
    );
  }
}

/// What the setup printed, folded away until asked for.
class _SetupLog extends StatelessWidget {
  const _SetupLog(this.log);

  final String log;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text("Log", style: Theme.of(context).textTheme.bodyMedium),
    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
    childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
    shape: const Border(),
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SelectionArea(child: LiveShellOutput(code: log)),
      ),
    ],
  );
}

/// Each tool and the version found, "Not installed" where none was — a probe
/// that failed outright included.
class _ToolStatusList extends ConsumerWidget {
  const _ToolStatusList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(byteRepairToolVersionsProvider);
    final theme = Theme.of(context);
    if (versions.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final found = versions.asData?.value ?? const <String, String?>{};
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
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
                      found[tool] ?? "Not installed",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: found[tool] != null
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
    );
  }
}
