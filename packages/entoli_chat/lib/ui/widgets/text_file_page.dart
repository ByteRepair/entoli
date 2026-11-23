import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:re_editor/re_editor.dart";

import "../../core/code_grammars.dart" show grammarOfFile;
import "../../core/formatting.dart";
import "../../domain/workspace.dart";
import "../../app/handoff.dart";
import "../../app/storage.dart";
import "busy.dart";
import "dialogs.dart";
import "discard_guard.dart";
import "document_view.dart";
import "empty_pane.dart";
import "page_bar.dart";

/// Opens [path] in [TextFilePage] where no caller is left to hand a file
/// whose bytes are not text to another app.
Future<void> openTextFile(BuildContext context, String path, String name) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TextFilePage(path: path, name: name, popsBinary: false),
      ),
    );

/// A text file, read and edited in the app rather than handed to another —
/// a workspace file, or an instruction file the user linked. See
/// `lib/ui/workspace/AGENTS.md`, "The workspace explorer".
class TextFilePage extends ConsumerStatefulWidget {
  const TextFilePage({
    super.key,
    required this.path,
    required this.name,
    this.popsBinary = true,
    this.readOnly = false,
  });

  final String path;

  /// What the bar says. The caller already has it.
  final String name;

  /// Whether a file whose bytes are not text pops `true` for the caller to
  /// hand off, rather than saying so here.
  final bool popsBinary;

  /// Read and never edited: a file of a chat shared from someone else.
  final bool readOnly;

  @override
  ConsumerState<TextFilePage> createState() => _TextFilePageState();
}

class _TextFilePageState extends ConsumerState<TextFilePage> {
  WorkspaceText? _content;
  Object? _error;
  final _busy = ValueNotifier(false);
  CodeLineEditingController? _controller;
  late final _markdown = grammarOfFile(widget.name)?.name == "markdown";

  bool _editing = false;

  /// What is on disk, as the editor would write it back: the controller
  /// normalises line breaks to the one it was given, so comparing against the
  /// file as read would call a mixed-break file changed before a key was
  /// pressed.
  String _saved = "";
  CodeLines? _lines;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    DocumentReading.wrap.addListener(_rewrap);
    _load();
  }

  /// Alt+W flips it in the editor, and the menu's tick follows.
  void _rewrap() => setState(() {});

  @override
  void dispose() {
    DocumentReading.wrap.removeListener(_rewrap);
    _busy.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final content = await ref
          .read(workspaceProvider)
          .readTextHead(widget.path);
      if (!mounted) return;
      // The name said text and the bytes disagree. Popping `true` puts the
      // hand-off back on the explorer, which stays on screen to say so if it
      // fails.
      if (content == null) {
        if (widget.popsBinary) return Navigator.of(context).pop(true);
        return setState(() => _error = "It is not a text file.");
      }
      if (content.truncated) return setState(() => _content = content);
      final controller = documentController(content.text)
        ..addListener(_changed);
      _controller?.dispose();
      setState(() {
        _content = content;
        _controller = controller;
        _lines = controller.codeLines;
        _saved = controller.text;
        _dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _changed() {
    // The controller notifies on every caret move too, and `text` joins the
    // whole document; a selection change keeps the same lines.
    final lines = _controller!.codeLines;
    if (identical(lines, _lines)) return;
    _lines = lines;
    final dirty = _controller!.text != _saved;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _handOff() => whileBusy(
    context,
    _busy,
    () => ref.read(fileHandoffProvider).open(widget.path),
  );

  /// A plain write rather than through a rename: a rename makes a new file,
  /// which drops the mode an agent's script was given.
  Future<void> _save() => whileBusy(context, _busy, () async {
    final text = _controller!.text;
    await ref.read(fileSystemProvider).file(widget.path).writeAsString(text);
    if (!mounted) return;
    setState(() {
      _saved = text;
      _dirty = _controller!.text != text;
    });
    notify(context, "Saved ${widget.name}");
  });

  /// Past the cap only the head was read, which is not the file, so nothing of
  /// it is shown or edited.
  bool get _tooLarge => _content?.truncated ?? false;

  /// The whole file, read now for the clipboard alone when it is too large to
  /// have been read for the page.
  Future<void> _copy() => whileBusy(context, _busy, () async {
    final text = _tooLarge
        ? await ref.read(fileSystemProvider).file(widget.path).readAsString()
        : _controller!.text;
    if (mounted) {
      await copyToClipboard(context, text, said: "Copied ${widget.name}");
    }
  });

  /// Markdown previews rendered; everything else is the editor, read-only
  /// until Edit.
  bool get _showsEditor => _editing || !_markdown;

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return DiscardGuard(
      edited: () => _dirty,
      title: "Discard your changes?",
      message: "${widget.name} has edits that have not been saved.",
      child: Scaffold(
        appBar: PageBar(
          title: _dirty ? "${widget.name} •" : widget.name,
          actions: controller == null
              ? const []
              : [
                  if (_editing) ...[
                    PageAction.icon(
                      icon: Icons.save_outlined,
                      label: "Save",
                      onPressed: _dirty ? _save : null,
                    ),
                    PageAction.icon(
                      icon: Icons.visibility_outlined,
                      label: "Preview",
                      onPressed: () => setState(() => _editing = false),
                    ),
                  ] else if (!widget.readOnly)
                    PageAction.icon(
                      icon: Icons.edit_outlined,
                      label: "Edit",
                      onPressed: () => setState(() => _editing = true),
                    ),
                  _menu(),
                ],
        ),
        body: Column(
          children: [
            BusyBar(_busy),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  PageAction _menu() => PageAction.menu(
    label: "More",
    items: [
      if (_showsEditor)
        PageMenuItem(
          label: "Wrap lines",
          checked: DocumentReading.wrap.value,
          onSelected: () =>
              DocumentReading.wrap.value = !DocumentReading.wrap.value,
        ),
      PageMenuItem(
        label: "Text size",
        icon: Icons.format_size,
        onSelected: _pickTextSize,
      ),
      PageMenuItem(
        label: "Copy",
        icon: Icons.copy_all_outlined,
        onSelected: _copy,
      ),
      PageMenuItem(
        label: "Open in another app",
        icon: Icons.open_in_new,
        onSelected: _handOff,
      ),
    ],
  );

  /// A slider rather than two menu entries, since a menu closes on every step.
  void _pickTextSize() => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: ValueListenableBuilder(
          valueListenable: DocumentReading.textScale,
          builder: (context, scale, _) => Row(
            children: [
              const Icon(Icons.text_decrease),
              Expanded(
                child: Slider(
                  value: scale,
                  min: DocumentReading.minScale,
                  max: DocumentReading.maxScale,
                  divisions: 18,
                  label: "${(scale * 100).round()}%",
                  onChanged: DocumentReading.scaleTo,
                ),
              ),
              const Icon(Icons.text_increase),
              TextButton(
                onPressed: () => DocumentReading.scaleTo(1),
                child: const Text("Reset"),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _body() {
    if (_error != null) {
      return EmptyPane(
        icon: Icons.error_outline,
        title: "That file could not be read",
        detail: "$_error",
        action: TextButton(onPressed: _retry, child: const Text("Try again")),
      );
    }
    final content = _content;
    if (content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (content.truncated) {
      return EmptyPane(
        icon: Icons.description_outlined,
        title: "Too large to show here",
        detail: "Files over ${formatSize(textViewLimit)} open in another app.",
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _handOff,
              icon: const Icon(Icons.open_in_new),
              label: const Text("Open in another app"),
            ),
            OutlinedButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text("Copy text"),
            ),
          ],
        ),
      );
    }
    final mod = Theme.of(context).platform == TargetPlatform.macOS;
    return DocumentEditor(
      controller: _controller!,
      name: widget.name,
      markdown: _markdown,
      editing: _editing,
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.keyS, control: !mod, meta: mod): () {
          if (_editing && _dirty) _save();
        },
      },
    );
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }
}
