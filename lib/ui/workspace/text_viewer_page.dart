import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/workspace.dart";
import "../../providers.dart";
import "../fonts.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/formatting.dart";

/// A text file from a workspace, read rather than handed to another app. It is
/// a viewer and not an editor: the text is selectable and copyable and that is
/// the whole of what it does — see CLAUDE.md, "The workspace explorer".
class TextViewerPage extends ConsumerStatefulWidget {
  const TextViewerPage({super.key, required this.path, required this.name});

  final String path;

  /// What the app bar says. The explorer already has it, and the page would
  /// otherwise take it apart from the path again.
  final String name;

  @override
  ConsumerState<TextViewerPage> createState() => _TextViewerPageState();
}

class _TextViewerPageState extends ConsumerState<TextViewerPage> {
  WorkspaceText? _content;
  Object? _error;
  final _busy = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final content =
          await readTextHead(ref.read(appConfigProvider).fs, widget.path);
      if (!mounted) return;
      // The name said text and the bytes disagree, so this was the hand-off's
      // after all: leave rather than draw the file as mojibake.
      if (content == null) return _fallBack();
      setState(() => _content = content);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _handOff() =>
      whileBusy(context, _busy, () => ref.read(fileHandoffProvider).open(widget.path));

  /// The page goes first and the hand-off follows it, so nothing here can
  /// touch a disposed state: the messenger is the app's rather than this
  /// route's, which is what leaves somewhere to say a refusal.
  Future<void> _fallBack() async {
    final handoff = ref.read(fileHandoffProvider);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await handoff.open(widget.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("That did not work: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: "Copy",
            onPressed: content == null
                ? null
                : () => copyToClipboard(context, content.text,
                    said: content.truncated
                        ? "Copied what is shown"
                        : "Copied ${widget.name}"),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: "Open in another app",
            onPressed: _handOff,
          ),
        ],
      ),
      body: Column(
        children: [
          BusyBar(_busy),
          if (content != null && content.truncated) const _Truncated(),
          Expanded(child: _body(content)),
        ],
      ),
    );
  }

  Widget _body(WorkspaceText? content) {
    if (_error != null) return _Failed(error: _error!, onRetry: _retry);
    if (content == null) return const Center(child: CircularProgressIndicator());
    if (content.text.isEmpty) return const Center(child: Text("This file is empty"));
    return Scrollbar(
      child: SingleChildScrollView(
        primary: true,
        padding: const EdgeInsets.all(16),
        // A long line scrolls rather than wraps: what is being read is a log or
        // a source file, where a wrapped line is a line that lost its column.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            content.text,
            style: const TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.4),
          ),
        ),
      ),
    );
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }
}

class _Truncated extends StatelessWidget {
  const _Truncated();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        "Showing the first ${formatSize(textViewLimit)}. "
        "Open the file in another app to read the rest.",
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            const Text("That file could not be read"),
            const SizedBox(height: 4),
            Text(
              "$error",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text("Try again")),
          ],
        ),
      ),
    );
  }
}
