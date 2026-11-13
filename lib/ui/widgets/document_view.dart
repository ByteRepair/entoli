import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:re_editor/re_editor.dart";
import "package:re_highlight/styles/github-dark.dart";
import "package:re_highlight/styles/github.dart";

import "../../app/settings/controller.dart";
import "../../core/code_grammars.dart" show grammarOfFile;
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/markdown_text.dart";
import "../fonts.dart";

/// A [DocumentController]'s text as the whole of a page: markdown rendered
/// while it is read, anything else in `re_editor`'s editor, read-only until
/// the page says it is being edited, each edit said back to the controller.
class DocumentView extends ConsumerStatefulWidget {
  const DocumentView(this.c, {super.key});

  final DocumentController c;

  @override
  ConsumerState<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends ConsumerState<DocumentView> {
  late final CodeLineEditingController _controller =
      CodeLineEditingController.fromText(
        widget.c.text,
        CodeLineOptions(
          lineBreak: widget.c.text.contains("\r\n")
              ? TextLineBreak.crlf
              : TextLineBreak.lf,
        ),
      )..addListener(_changed);
  late final _grammar = grammarOfFile(widget.c.name);
  CodeLines? _lines;

  /// The reader's, not the file's, so they outlive the page for the session.
  static bool _wrap = false;
  static double _textScale = 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _changed() {
    // The controller notifies on every caret move too; a selection change
    // keeps the same lines.
    final lines = _controller.codeLines;
    if (identical(lines, _lines)) return;
    _lines = lines;
    widget.c.edit(_controller.text);
  }

  void _setScale(double scale) =>
      setState(() => _textScale = scale.clamp(0.6, 2.4));

  @override
  Widget build(BuildContext context) {
    final mod = Theme.of(context).platform == TargetPlatform.macOS;
    final c = widget.c;
    final body = c.text.isEmpty && !c.editing
        ? const Center(child: Text("This file is empty"))
        : c.editing || !c.markdown
        ? _editor()
        : _markdown(c.text);
    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.equal,
          control: !mod,
          meta: mod,
        ): () =>
            _setScale(_textScale + 0.1),
        SingleActivator(
          LogicalKeyboardKey.minus,
          control: !mod,
          meta: mod,
        ): () =>
            _setScale(_textScale - 0.1),
        SingleActivator(
          LogicalKeyboardKey.digit0,
          control: !mod,
          meta: mod,
        ): () =>
            _setScale(1),
        SingleActivator(LogicalKeyboardKey.keyW, alt: true): () =>
            setState(() => _wrap = !_wrap),
      },
      child: Focus(autofocus: true, child: body),
    );
  }

  Widget _markdown(String text) => MediaQuery.withClampedTextScaling(
    minScaleFactor: _textScale,
    maxScaleFactor: _textScale,
    child: SelectionArea(
      child: Scrollbar(
        child: SingleChildScrollView(
          primary: true,
          padding: const EdgeInsets.all(16),
          child: MarkdownText(
            text,
            onTapLink: (href) {
              final uri = Uri.tryParse(href);
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

  Widget _editor() {
    final theme = Theme.of(context);
    final base = codeBlockStyle(theme);
    final grammar = _grammar;
    final scheme = theme.colorScheme;
    final editing = widget.c.editing;
    return CodeEditor(
      // Keyed so flipping read-only rebuilds the field with the caret it
      // should have, rather than carrying focus over from a read.
      key: ValueKey(editing),
      controller: _controller,
      readOnly: !editing,
      autofocus: editing,
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
        cursorLineColor: editing ? scheme.surfaceContainerHighest : null,
        codeTheme: grammar == null
            ? null
            : CodeHighlightTheme(
                languages: {
                  grammar.name: CodeHighlightThemeMode(mode: grammar.mode),
                },
                theme: theme.brightness == Brightness.dark
                    ? githubDarkTheme
                    : githubTheme,
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
}
