import "package:file_selector/file_selector.dart";
import "package:flutter/foundation.dart" show defaultTargetPlatform, TargetPlatform;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/local/byte_repair_store.dart";
import "../../domain/builtin_project.dart";
import "../../providers.dart";
import "../widgets/destructive_button.dart";
import "../widgets/section_header.dart";
import "../widgets/settings_warning_banner.dart";

/// The Byte Repair category: whether the configured terminal env can run its
/// tooling, a button that installs it, a button to import a local ESBMC
/// binary, a button to delete the whole environment, and the versions found
/// afterwards.
///
/// On Android the "Host" terminal env has no package manager, so the category
/// says so and hides the rest — nothing here can run until a rootfs is picked
/// from the Terminal settings. On every other platform the host shell is the
/// only env and is capable.
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
    final rootfsId = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final incompatible = isAndroid && rootfsId == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Byte Repair",
          description: "Installs ESBMC and supporting tooling for formal "
              "verification of C code. Runs through the configured terminal "
              "environment, so it needs one with a package manager.",
        ),
        if (incompatible)
          SettingsWarningBanner(
            icon: Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            text: 'Byte Repair does not work when using the "Host" terminal '
                "environment on this device. Please choose another terminal "
                "environment.",
          )
        else ...[
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
          if (_error != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _ToolStatusList(),
          const SizedBox(height: 8),
          DestructiveButton(
            icon: Icons.delete_outline,
            label: "Delete Byte Repair Data",
            confirmTitle: "Delete Byte Repair environment?",
            confirmMessage: "This deletes the Byte Repair rootfs (the Linux "
                "copy and everything installed into it), its workspace "
                "(cloned repos, scratch files), and all chats in the "
                "project. Run Setup to use Byte Repair again.",
            onConfirmed: () async {
              // The environment first: it is the half that can fail, and
              // failing before the chats are gone leaves the user something
              // to retry with.
              final store = ref.read(byteRepairStoreProvider);
              final error = await store.deleteEnvironment();
              if (!mounted) return;
              if (error != null) {
                setState(() => _error = error);
                return;
              }
              final repo = ref.read(chatRepositoryProvider);
              final project = ByteRepairProject().dir;
              final chats = await repo.listChats();
              await Future.wait(
                chats.where((c) => c.project == project).map((c) => repo.deleteChat(c.id)),
              );
              if (!mounted) return;
              ref.invalidate(byteRepairToolVersionsProvider);
              ref.invalidate(setupCompleteProvider(project));
              ref.invalidate(chatListProvider);
            },
          ),
        ],
      ],
    );
  }

  Future<void> _runSetup() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final store = ref.read(byteRepairStoreProvider);
      final shell = ref.read(shellProvider);
      final result = await store.install(shell);
      if (!mounted) return;
      if (result.returnCode == 0) {
        ref.invalidate(byteRepairToolVersionsProvider);
        ref.invalidate(setupCompleteProvider(ByteRepairProject().dir));
      } else {
        setState(() {
          _error = result.exceptionInfo ?? result.output.trim();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _importEsbmc() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      const type = XTypeGroup(label: "ESBMC binary");
      final file = await openFile(acceptedTypeGroups: const [type]);
      if (file == null) return;
      final store = ref.read(byteRepairStoreProvider);
      final error = await store.importEsbmc(file);
      if (!mounted) return;
      if (error != null) {
        setState(() => _error = error);
      } else {
        ref.invalidate(byteRepairToolVersionsProvider);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
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
        error: (e, st) => Text(
          "Not installed",
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
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
                      child: Text(
                        tool,
                        style: theme.textTheme.bodySmall,
                      ),
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