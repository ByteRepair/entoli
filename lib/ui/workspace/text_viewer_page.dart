import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/workspace.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart" show codeBlockStyle;
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/empty_pane.dart";
import "../widgets/formatting.dart";

/// A text file from a workspace, read rather than handed to another app — see
/// CLAUDE.md, "The workspace explorer".
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
      // The name said text and the bytes disagree. Popping `true` puts the
      // hand-off back on the explorer, which is what stays on screen to say so
      // if it fails.
      if (content == null) return Navigator.of(context).pop(true);
      setState(() => _content = content);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _handOff() =>
      whileBusy(context, _busy, () => ref.read(fileHandoffProvider).open(widget.path));

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
    if (_error != null) {
      return EmptyPane(
        icon: Icons.error_outline,
        title: "That file could not be read",
        detail: "$_error",
        action: TextButton(onPressed: _retry, child: const Text("Try again")),
      );
    }
    if (content == null) return const Center(child: CircularProgressIndicator());
    if (content.text.isEmpty) return const Center(child: Text("This file is empty"));
    return Scrollbar(
      child: SingleChildScrollView(
        primary: true,
        padding: const EdgeInsets.all(16),
        // A long line scrolls rather than wraps.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(content.text, style: codeBlockStyle(Theme.of(context))),
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
