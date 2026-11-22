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

/// How a document is read: the reader's, not the file's, so both outlive the
/// page for the session and every document page shares them.
abstract final class DocumentReading {
  static final wrap = ValueNotifier(false);
  static final textScale = ValueNotifier(1.0);

  static void scaleTo(double scale) =>
      textScale.value = scale.clamp(minScale, maxScale);

  static const minScale = 0.6;
  static const maxScale = 2.4;
}

/// An editor's controller over [text], keeping the line break the text was
/// written with: its `text` is then what a save writes back.
CodeLineEditingController documentController(String text) =>
    CodeLineEditingController.fromText(
      text,
      CodeLineOptions(
        lineBreak: text.contains("\r\n")
            ? TextLineBreak.crlf
            : TextLineBreak.lf,
      ),
    );

/// A document's text as the whole of a page: markdown rendered while it is
/// read, anything else in `re_editor`'s editor, read-only until [editing].
/// The caller owns [controller] and hears its edits there.
class DocumentEditor extends ConsumerWidget {
  const DocumentEditor({
    super.key,
    required this.controller,
    required this.name,
    required this.markdown,
    this.editing = false,
    this.placeholder,
    this.shortcuts = const {},
  });

  final CodeLineEditingController controller;

  /// The file's name, which says how it is highlighted.
  final String name;

  /// Rendered rather than shown as source while it is read.
  final bool markdown;
  final bool editing;
  final String? placeholder;

  /// The page's own keys, beside the reading ones.
  final Map<ShortcutActivator, VoidCallback> shortcuts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mod = Theme.of(context).platform == TargetPlatform.macOS;
    SingleActivator key(LogicalKeyboardKey k) =>
        SingleActivator(k, control: !mod, meta: mod);
    final scale = DocumentReading.textScale;
    return CallbackShortcuts(
      bindings: {
        ...shortcuts,
        key(LogicalKeyboardKey.equal): () =>
            DocumentReading.scaleTo(scale.value + 0.1),
        key(LogicalKeyboardKey.minus): () =>
            DocumentReading.scaleTo(scale.value - 0.1),
        key(LogicalKeyboardKey.digit0): () => DocumentReading.scaleTo(1),
        const SingleActivator(LogicalKeyboardKey.keyW, alt: true): () =>
            DocumentReading.wrap.value = !DocumentReading.wrap.value,
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: Listenable.merge([scale, DocumentReading.wrap]),
          builder: (context, _) {
            final text = controller.text;
            if (text.isEmpty && !editing) {
              return const Center(child: Text("This file is empty"));
            }
            return editing || !markdown
                ? _editor(context)
                : _markdown(context, ref, text);
          },
        ),
      ),
    );
  }

  Widget _markdown(BuildContext context, WidgetRef ref, String text) {
    final scale = DocumentReading.textScale.value;
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: scale,
      maxScaleFactor: scale,
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
  }

  Widget _editor(BuildContext context) {
    final theme = Theme.of(context);
    final base = codeBlockStyle(theme);
    final grammar = grammarOfFile(name);
    final scheme = theme.colorScheme;
    final scale = DocumentReading.textScale.value;
    return CodeEditor(
      // Keyed so flipping read-only rebuilds the field with the caret it
      // should have, rather than carrying focus over from a read.
      key: ValueKey(editing),
      controller: controller,
      readOnly: !editing,
      autofocus: editing,
      hint: placeholder,
      wordWrap: DocumentReading.wrap.value,
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
      style: CodeEditorStyle(
        fontSize: base.fontSize! * scale,
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
              fontSize: base.fontSize! * scale,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            focusedTextStyle: base.copyWith(
              fontSize: base.fontSize! * scale,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// A [DocumentController]'s text as a [DocumentEditor], each edit said back
/// to the controller.
class DocumentView extends StatefulWidget {
  const DocumentView(this.c, {super.key});

  final DocumentController c;

  @override
  State<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<DocumentView> {
  late final _controller = documentController(widget.c.text)
    ..addListener(_changed);
  CodeLines? _lines;

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

  @override
  Widget build(BuildContext context) => DocumentEditor(
    controller: _controller,
    name: widget.c.name,
    markdown: widget.c.markdown,
    editing: widget.c.editing,
    placeholder: widget.c.placeholder,
  );
}
