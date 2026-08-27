import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/skill_import.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../chat/widgets/reply_style.dart";
import "../widgets/dialogs.dart";

/// A full page that shows a skill the model drafted and packaged, with an
/// Install button. Pushed from [SkillInstallLabel]'s tap; back gesture closes.
class SkillInstallPreviewPage extends ConsumerStatefulWidget {
  const SkillInstallPreviewPage({
    super.key,
    required this.chatId,
    required this.installId,
  });

  final String chatId;
  final String installId;

  @override
  ConsumerState<SkillInstallPreviewPage> createState() =>
      _SkillInstallPreviewPageState();
}

class _SkillInstallPreviewPageState
    extends ConsumerState<SkillInstallPreviewPage> {
  SkillPackage? _package;
  bool _loading = true;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _loadPackage();
  }

  Future<void> _loadPackage() async {
    final store = ref.read(chatStoreProvider);
    try {
      final bytes =
          await store.readSkillInstall(widget.chatId, widget.installId);
      if (bytes == null) {
        if (mounted) {
          setState(() => _loading = false);
        }
        return;
      }
      final pkg = parseSkillPackage(Uint8List.fromList(bytes));
      if (mounted) {
        setState(() {
          _package = pkg;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install() async {
    final pkg = _package;
    if (pkg == null) return;
    setState(() => _installing = true);
    final config = ref.read(appConfigProvider);
    final skillsDir = config.promptsDir(CompletionKind.skill);
    final replacing =
        await config.fs.directory(skillDirectory(config, pkg.name)).exists();
    if (mounted && replacing) {
      final confirmed = await confirm(
        context,
        title: "Replace ${pkg.name}?",
        message: "A skill with that name is already installed. Installing "
            "this one replaces it, files included.",
        confirmLabel: "Replace",
      );
      if (!confirmed) {
        if (mounted) setState(() => _installing = false);
        return;
      }
    }
    await platform.withWritableDir(skillsDir, () async {
      await installSkillPackage(config, pkg);
    });
    await ref.read(promptLibraryProvider.notifier).reload();
    if (mounted) {
      setState(() => _installing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Installed ${pkg.name}.")),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text("Install skill")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _package == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      "The skill package could not be read. It may have been "
                      "deleted with the chat.",
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _previewBody(theme),
      bottomNavigationBar: _package == null || _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _installing ? null : _install,
                  icon: _installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.install_desktop),
                  label: Text(_installing ? "Installing…" : "Install skill"),
                ),
              ),
            ),
    );
  }

  Widget _previewBody(ThemeData theme) {
    final pkg = _package!;
    final otherFiles = pkg.entries.where((e) => e.$1 != "SKILL.md").toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(pkg.name, style: theme.textTheme.headlineSmall),
        if (pkg.description != null) ...[
          const SizedBox(height: 4),
          Text(pkg.description!, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 24),
        Text("SKILL.md", style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(16),
          child: MarkdownBody(
            data: pkg.body,
            styleSheet: replyStyleSheet(theme),
          ),
        ),
        if (otherFiles.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text("Files", style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final (name, _) in otherFiles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(name, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
        ],
      ],
    );
  }
}