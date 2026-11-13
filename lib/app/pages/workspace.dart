import "package:path/path.dart" as p;

import "../../core/formatting.dart";
import "../../domain/workspace.dart";
import "../../providers.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";
import "text_file.dart";

/// A workspace folder and what is in it: a folder opens over this one, a
/// text file in the app's own viewer and anything else in another app;
/// a new folder is made, an entry deleted or shared, and the folder shown
/// in the file manager where there is one. See "The workspace explorer" in
/// `lib/ui/workspace/AGENTS.md`.
class WorkspaceAppPage extends AppPage {
  WorkspaceAppPage({required this.root, required this.owner, String? dir})
    : dir = dir ?? root;

  /// The folder the explorer cannot go above.
  final String root;

  /// What the page says at the root: whose workspace this is.
  final String owner;

  final String dir;

  List<WorkspaceEntry>? _entries;
  Object? _error;

  @override
  String get address => "workspace/$dir";

  bool get _atRoot => dir == root;

  @override
  void opened() => _read();

  Future<void> _read() async {
    try {
      _entries = await listWorkspace(dir);
      _error = null;
    } catch (e) {
      _error = e;
    }
    changed();
  }

  @override
  String title(SettingReader reader) => _atRoot ? owner : p.basename(dir);

  @override
  String? subtitle(SettingReader reader) =>
      _atRoot ? null : p.relative(dir, from: root);

  @override
  List<PageSection> sections(SettingReader reader) {
    final handoff = reader.watch(fileHandoffProvider);
    final entries = _entries;
    if (entries == null) {
      return [
        notice(
          "loading",
          _error == null ? "Reading the folder…" : "$_error",
          tone: _error == null ? NoticeTone.plain : NoticeTone.warning,
        ),
      ];
    }
    return [
      PageSection("entries", "", [
        CollectionController<WorkspaceEntry>(
          part("entries", "Files", hint: UiHint.info),
          items: entries,
          removable: false,
          emptyLabel: handoff.canShare
              ? "Nothing here yet. The agent's files land here; share files "
                    "to Entoli to add your own."
              : "Nothing here yet. The agent's files land here.",
          addLabel: "New Folder…",
          form: (_) => _NewFolder(dir),
          submit: (answers, _) async {
            await createFolder(dir, answers["name"] ?? "");
            await _read();
          },
          describe: (entry) => CollectionItem(
            entry.name,
            subtitle: entry.isDirectory ? null : formatSize(entry.size),
            glyph: entry.isDirectory ? SettingGlyph.folder : SettingGlyph.file,
            editable: false,
            takesImage: false,
            tap: "open",
            actions: [
              if (handoff.canShare) const ItemAction("share", "Share…"),
              ItemAction(
                "delete",
                "Delete",
                destructive: true,
                confirm: SettingConfirm(
                  title: "Delete \"${entry.name}\"?",
                  message: entry.isDirectory
                      ? "The folder goes with everything in it. This cannot "
                            "be undone."
                      : "This cannot be undone.",
                  confirmLabel: "Delete",
                  destructive: true,
                ),
              ),
            ],
          ),
          act: (index, action) => _act(entries[index], action),
        ),
      ]),
    ];
  }

  Future<SettingNotice?> _act(WorkspaceEntry entry, String action) async {
    switch (action) {
      case "open":
        return _open(entry);
      case "share":
        await app.read(fileHandoffProvider).export([entry.path]);
      case "delete":
        await deleteEntries([entry.path]);
        await _read();
    }
    return null;
  }

  /// A folder opens over this one; a text file in the app's viewer, which
  /// hands the file on itself if its bytes turn out not to be text.
  Future<SettingNotice?> _open(WorkspaceEntry entry) async {
    if (entry.isDirectory) {
      pages.open(WorkspaceAppPage(root: root, owner: owner, dir: entry.path));
    } else if (looksTextual(entry.name)) {
      pages.open(TextFileAppPage(path: entry.path, name: entry.name));
    } else {
      await app.read(fileHandoffProvider).open(entry.path);
    }
    return null;
  }

  @override
  List<ActionController> toolbar(SettingReader reader) {
    final handoff = reader.watch(fileHandoffProvider);
    return [
      if (handoff.canReveal)
        ActionController(
          part("reveal", "Show in File Manager", glyph: SettingGlyph.folder),
          run: () async {
            await handoff.reveal(dir);
            return null;
          },
        ),
    ];
  }
}

/// A new folder's name.
class _NewFolder extends SettingForm<WorkspaceEntry> {
  const _NewFolder(this.dir);

  final String dir;

  @override
  String get title => "New Folder";

  @override
  Map<String, String> get initial => const {"name": ""};

  @override
  List<FormFieldSpec> fields(Map<String, String> answers) => const [
    FormText("name", "Name"),
  ];

  @override
  String? problem(Map<String, String> answers) =>
      (answers["name"] ?? "").trim().isEmpty ? "Name the folder." : null;

  @override
  WorkspaceEntry build(Map<String, String> answers) => WorkspaceEntry(
    path: p.join(dir, answers["name"]!.trim()),
    name: answers["name"]!.trim(),
    isDirectory: true,
    size: 0,
  );
}
