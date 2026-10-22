import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:re_editor/re_editor.dart";
import "package:re_highlight/styles/github-dark.dart";
import "package:re_highlight/styles/github.dart";

import "../../domain/workspace.dart";
import "../fonts.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/reply_style.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/empty_pane.dart";
import "../widgets/formatting.dart";

/// A text file from a workspace, read rather than handed to another app — see
/// AGENTS.md, "The workspace explorer".
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
  CodeLineEditingController? _controller;
  late final _grammar = grammarOfFile(widget.name);

  bool _editing = false;

  /// What is on disk, as the editor would write it back: the controller
  /// normalises line breaks to the one it was given, so comparing against the
  /// file as read would call a CRLF file changed before a key was pressed.
  String _saved = "";
  bool _dirty = false;

  /// The reader's, not the file's, so they outlive the page for the session.
  static bool _wrap = false;
  static double _textScale = 1;

  /// Rendered markdown is laid out whole, where the editor lays out what is on
  /// screen.
  bool get _rendersMarkdown =>
      _grammar?.name == "markdown" && (_content?.text.length ?? 0) <= markdownPreviewLimit;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _busy.dispose();
    _controller?.dispose();
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
      final controller = CodeLineEditingController.fromText(
        content.text,
        CodeLineOptions(
          lineBreak: content.text.contains("\r\n") ? TextLineBreak.crlf : TextLineBreak.lf,
        ),
      )..addListener(_changed);
      _controller?.dispose();
      setState(() {
        _content = content;
        _controller = controller;
        _saved = controller.text;
        _dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _changed() {
    final dirty = _controller!.text != _saved;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _handOff() =>
      whileBusy(context, _busy, () => ref.read(fileHandoffProvider).open(widget.path));

  /// A plain write rather than through a rename: a rename makes a new file,
  /// which drops the mode an agent's script was given.
  Future<void> _save() => whileBusy(context, _busy, () async {
        final text = _controller!.text;
        await ref.read(appConfigProvider).fs.file(widget.path).writeAsString(text);
        if (!mounted) return;
        setState(() {
          _saved = text;
          _dirty = _controller!.text != text;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Saved ${widget.name}")));
      });

  /// A truncated file is only its head, and saving it would cut the rest off.
  bool get _canEdit => _content != null && !_content!.truncated;

  void _setScale(double scale) => setState(() => _textScale = scale.clamp(0.6, 2.4));

  Future<bool> _leave() async {
    if (!_dirty) return true;
    return confirm(
      context,
      title: "Discard your changes?",
      message: "${widget.name} has edits that have not been saved.",
      confirmLabel: "Discard",
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;
    final mod = Theme.of(context).platform == TargetPlatform.macOS;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _leave() && context.mounted) Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: {
          SingleActivator(LogicalKeyboardKey.keyS, control: !mod, meta: mod): () {
            if (_editing && _dirty) _save();
          },
          SingleActivator(LogicalKeyboardKey.equal, control: !mod, meta: mod): () =>
              _setScale(_textScale + 0.1),
          SingleActivator(LogicalKeyboardKey.minus, control: !mod, meta: mod): () =>
              _setScale(_textScale - 0.1),
          SingleActivator(LogicalKeyboardKey.digit0, control: !mod, meta: mod): () =>
              _setScale(1),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                _dirty ? "${widget.name} •" : widget.name,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (_editing && _canEdit)
                  IconButton(
                    icon: const Icon(Icons.save_outlined),
                    tooltip: "Save",
                    onPressed: _dirty ? _save : null,
                  ),
                if (_editing)
                  IconButton(
                    icon: const Icon(Icons.visibility_outlined),
                    tooltip: "Preview",
                    onPressed: () => setState(() => _editing = false),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: _content?.truncated ?? false
                        ? "Too large to edit here"
                        : "Edit",
                    onPressed: _canEdit ? () => setState(() => _editing = true) : null,
                  ),
                _menu(content),
              ],
            ),
            body: Column(
              children: [
                BusyBar(_busy),
                if (content != null && content.truncated) const _Truncated(),
                Expanded(child: _body(content)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu(WorkspaceText? content) => PopupMenuButton<void Function()>(
        tooltip: "More",
        onSelected: (action) => action(),
        itemBuilder: (context) => [
          if (_showsEditor)
            CheckedPopupMenuItem(
              checked: _wrap,
              value: () => setState(() => _wrap = !_wrap),
              child: const Text("Wrap lines"),
            ),
          PopupMenuItem(
            value: _pickTextSize,
            child: const ListTile(
              leading: Icon(Icons.format_size),
              title: Text("Text size"),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            enabled: content != null,
            value: () => copyToClipboard(context, _controller!.text,
                said: content!.truncated ? "Copied what is shown" : "Copied ${widget.name}"),
            child: const ListTile(
              leading: Icon(Icons.copy_all_outlined),
              title: Text("Copy"),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: _handOff,
            child: const ListTile(
              leading: Icon(Icons.open_in_new),
              title: Text("Open in another app"),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      );

  /// A slider rather than two menu entries, since a menu closes on every step.
  void _pickTextSize() => showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => StatefulBuilder(
          builder: (sheet, setSheet) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.text_decrease),
                  Expanded(
                    child: Slider(
                      value: _textScale,
                      min: 0.6,
                      max: 2.4,
                      divisions: 18,
                      label: "${(_textScale * 100).round()}%",
                      onChanged: (v) {
                        _setScale(v);
                        setSheet(() {});
                      },
                    ),
                  ),
                  const Icon(Icons.text_increase),
                  TextButton(
                    onPressed: () {
                      _setScale(1);
                      setSheet(() {});
                    },
                    child: const Text("Reset"),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// Markdown previews rendered; everything else is the editor, read-only
  /// until Edit.
  bool get _showsEditor => _editing || !_rendersMarkdown;

  Widget _body(WorkspaceText? content) {
    if (_error != null) {
      return EmptyPane(
        icon: Icons.error_outline,
        title: "That file could not be read",
        detail: "$_error",
        action: TextButton(onPressed: _retry, child: const Text("Try again")),
      );
    }
    final controller = _controller;
    if (content == null || controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (content.text.isEmpty && !_editing) {
      return const Center(child: Text("This file is empty"));
    }
    return _showsEditor ? _editor(controller) : _markdown(controller.text);
  }

  Widget _markdown(String text) {
    final theme = Theme.of(context);
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: _textScale,
      maxScaleFactor: _textScale,
      child: SelectionArea(
        child: Scrollbar(
          child: SingleChildScrollView(
            primary: true,
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(
              data: text,
              styleSheet: replyStyleSheet(theme),
              builders: codeBlockBuilders,
              onTapLink: (_, href, _) {
                final uri = href == null ? null : Uri.tryParse(href);
                // A relative link names a workspace file, which is no URL.
                if (uri != null && uri.hasScheme) {
                  ref.read(linkOpenerProvider).open(context, uri);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _editor(CodeLineEditingController controller) {
    final theme = Theme.of(context);
    final base = codeBlockStyle(theme);
    final grammar = _grammar;
    final scheme = theme.colorScheme;
    return CodeEditor(
      // Keyed so flipping read-only rebuilds the field with the caret it should
      // have, rather than carrying focus over from a read.
      key: ValueKey(_editing),
      controller: controller,
      readOnly: !_editing,
      autofocus: _editing,
      wordWrap: _wrap,
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
      style: CodeEditorStyle(
        fontSize: base.fontSize! * _textScale,
        fontFamily: monoFamily,
        fontHeight: base.height,
        textColor: scheme.onSurface,
        backgroundColor: scheme.surface,
        selectionColor: scheme.primary.withValues(alpha: 0.3),
        cursorColor: scheme.primary,
        cursorLineColor: _editing ? scheme.surfaceContainerHighest : null,
        codeTheme: grammar == null
            ? null
            : CodeHighlightTheme(
                languages: {grammar.name: CodeHighlightThemeMode(mode: grammar.mode)},
                theme: theme.brightness == Brightness.dark ? githubDarkTheme : githubTheme,
              ),
      ),
      indicatorBuilder: (context, editing, chunks, notifier) => Row(
        children: [
          DefaultCodeLineNumber(
            controller: editing,
            notifier: notifier,
            textStyle: base.copyWith(
              fontSize: base.fontSize! * _textScale,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            focusedTextStyle: base.copyWith(
              fontSize: base.fontSize! * _textScale,
              color: scheme.onSurface,
            ),
          ),
        ],
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
        "Open the file in another app to read or edit the rest.",
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
