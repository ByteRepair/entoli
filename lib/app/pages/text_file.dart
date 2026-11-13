import "dart:io";

import "../../core/formatting.dart";
import "../../domain/workspace.dart";
import "../../providers.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A text file, read and edited in the app rather than handed to another: a
/// workspace file, an instruction file the user linked. Markdown previews
/// rendered, anything else as highlighted code; Edit makes it writable and
/// Save writes it back in place. A file past [textViewLimit] is not shown,
/// only opened elsewhere or copied whole. See "The workspace explorer" in
/// `lib/ui/workspace/AGENTS.md`.
class TextFileAppPage extends AppPage {
  TextFileAppPage({
    required this.path,
    required this.name,
    this.handsOff = true,
  });

  final String path;
  final String name;

  /// Whether a file whose bytes are not text goes to another app rather
  /// than saying so here.
  final bool handsOff;

  WorkspaceText? _content;
  Object? _error;
  bool _editing = false;

  /// What is on disk, and the draft over it.
  String _saved = "";
  String _draft = "";

  bool get _dirty => _draft != _saved;
  bool get _tooLarge => _content?.truncated ?? false;

  @override
  String get address => "file/$path";

  @override
  void opened() => _load();

  Future<void> _load() async {
    try {
      final content = await readTextHead(path);
      if (content == null) {
        // The name said text and the bytes disagree.
        if (handsOff) {
          pages.leave(this);
          await app.read(fileHandoffProvider).open(path);
          return;
        }
        _error = "It is not a text file.";
      } else {
        _content = content;
        _saved = _draft = content.text;
      }
    } catch (e) {
      _error = e;
    }
    changed();
  }

  @override
  String title(SettingReader reader) => _dirty ? "$name •" : name;

  @override
  SettingConfirm? leaving(SettingReader reader) => _dirty
      ? SettingConfirm(
          title: "Discard your changes?",
          message: "$name has edits that have not been saved.",
          confirmLabel: "Discard",
          destructive: true,
        )
      : null;

  Future<SettingNotice?> _handOff() async {
    await app.read(fileHandoffProvider).open(path);
    return null;
  }

  /// The whole file, read now for the clipboard alone where it was too large
  /// to read for the page.
  Future<SettingNotice?> _copy() async {
    final text = _tooLarge ? await File(path).readAsString() : _draft;
    return SettingNotice("Copied $name", copy: text);
  }

  @override
  List<PageSection> sections(SettingReader reader) {
    final content = _content;
    if (_error != null || content == null) {
      return [
        PageSection("state", "", [
          NoticeController(
            part("state", _error == null ? "" : "That file could not be read"),
            tone: _error == null ? NoticeTone.plain : NoticeTone.warning,
            lines: [NoticeLine(_error == null ? "Reading…" : "$_error")],
          ),
        ]),
      ];
    }
    if (content.truncated) {
      return [
        PageSection("large", "Too large to show here", [
          NoticeController(
            part("large", ""),
            lines: [
              NoticeLine(
                "Files over ${formatSize(textViewLimit)} open in another app.",
              ),
            ],
          ),
          ActionController(part("open", "Open in Another App"), run: _handOff),
          ActionController(
            part("copy", "Copy Text"),
            secondary: true,
            run: _copy,
          ),
        ]),
      ];
    }
    return [
      PageSection.whole(
        "text",
        DocumentController(
          part("text", name),
          text: _draft,
          name: name,
          editing: _editing,
          onEdit: (text) {
            final was = _dirty;
            _draft = text;
            if (was != _dirty) changed();
          },
        ),
      ),
    ];
  }

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    if (_content != null && !_tooLarge) ...[
      if (_editing)
        ActionController(part("save", "Save"), enabled: _dirty, run: _save),
      ActionController(
        part("mode", _editing ? "Preview" : "Edit"),
        label: _editing ? "Preview" : "Edit",
        glyphOverride: _editing ? SettingGlyph.file : SettingGlyph.edit,
        run: () async {
          _editing = !_editing;
          changed();
          return null;
        },
      ),
      ActionController(part("copy", "Copy"), label: "Copy", run: _copy),
    ],
    ActionController(part("open", "Open in Another App"), run: _handOff),
  ];

  /// A plain write rather than through a rename: a rename makes a new file,
  /// which drops the mode an agent's script was given.
  Future<SettingNotice?> _save() async {
    final text = _draft;
    await File(path).writeAsString(text);
    _saved = text;
    changed();
    return SettingNotice("Saved $name");
  }
}
