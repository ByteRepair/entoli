import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../../core/platform/form_factor.dart";
import "../../domain/documents.dart" show RenameWriter;
import "../../domain/profile.dart";
import "../../domain/tone.dart";
import "../../providers.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";
import "prompt.dart";
import "text_file.dart";

/// What a turn knows about the user. With no [project] it is the app's
/// profile: the identity fields, which the prompt renders as "About the
/// user", how replies are worded, the global instructions every user
/// project's turns read and, on a desktop, instruction files linked from
/// elsewhere. With a [project] it is that project's instructions: the
/// AGENTS.md at its workspace root, its own answers for how replies are
/// worded, and which of the user's files it reads. A draft, saved whole.
class ProfileAppPage extends AppPage {
  ProfileAppPage({this.project});

  final String? project;

  bool get _global => project == null;

  bool _loaded = false;
  bool _saving = false;
  String _instructions = "";
  String _name = "";
  String _dob = "";
  String _religion = "";
  String _profession = "";
  Tone? _tone;
  bool? _citations;

  /// The linked instruction files, in reading order, and which of them and
  /// the global AGENTS.md the project switched off; which are not on disk,
  /// said on the row rather than dropped from it.
  List<String> _linked = [];
  Set<String> _off = {};
  Set<String> _missing = {};

  /// The app's answers, which a project's Default entries name.
  Tone _appTone = Tone.none;
  bool _appCitations = false;

  String? _opened;

  /// One writer of the instructions file, so two overlapping saves queue.
  final _write = RenameWriter();

  @override
  String get address => "profile/${project ?? ""}";

  @override
  void opened() => _load();

  String get _instructionsPath {
    final config = app.read(appConfigProvider);
    return _global
        ? config.globalInstructionsFile
        : config.projectInstructionsFile(project: project);
  }

  Future<void> _load() async {
    final config = app.read(appConfigProvider);
    try {
      final file = File(_instructionsPath);
      if (file.existsSync()) _instructions = await file.readAsString();
    } catch (_) {
      // A file that will not read is shown as empty; saving overwrites it.
    }
    // Linking is by path, which only a desktop's picker hands back.
    if (isDesktop) {
      final linked = await app.read(linkedInstructionsStoreProvider).load();
      _linked = [...linked.files];
      _off = {...?linked.off[project]};
      _missing = await _missingOf([config.globalInstructionsFile, ..._linked]);
    }
    final settings = app.read(appSettingsProvider);
    if (_global) {
      final profile = settings.profile;
      _name = profile?.name ?? "";
      _dob = profile?.dateOfBirth ?? "";
      _religion = profile?.religion ?? "";
      _profession = profile?.profession ?? "";
      _tone = settings.tone;
      _citations = settings.citations;
    } else {
      final own = app.read(projectSettingsProvider(project));
      _appTone = settings.tone;
      _appCitations = settings.citations;
      _tone = own.tone;
      _citations = own.citations;
    }
    _opened = _snapshot();
    _loaded = true;
    changed();
  }

  /// Together rather than in turn: a path on a stalled mount should cost the
  /// page its own wait, not everyone's after it.
  Future<Set<String>> _missingOf(List<String> paths) async {
    // ignore: avoid_slow_async_io
    final exists = await Future.wait(paths.map((p) => File(p).exists()));
    return {
      for (final (i, path) in paths.indexed)
        if (!exists[i]) path,
    };
  }

  /// Everything a save writes, as one comparable value.
  String _snapshot() => jsonEncode([
    _instructions,
    _name,
    _dob,
    _religion,
    _profession,
    _tone?.name,
    _citations,
    _linked,
    _off.toList()..sort(),
  ]);

  bool get _edited => _opened != null && _snapshot() != _opened;

  void _set(void Function() change) {
    change();
    changed();
  }

  @override
  String title(SettingReader reader) =>
      _global ? "Profile" : "Project Instructions";

  @override
  SettingConfirm? leaving(SettingReader reader) =>
      _edited ? AppPage.discardChanges : null;

  /// Typed in place, the draft taking each edit; trimmed on Save.
  TextController _field(
    String id,
    String title,
    String value,
    void Function(String) set, {
    String prompt = "Not set",
  }) => TextController(
    part(id, title, hint: UiHint.input),
    value: value,
    prompt: prompt,
    allowBlank: true,
    onSet: (text) async {
      _set(() => set(text));
      return null;
    },
  );

  @override
  List<PageSection> sections(SettingReader reader) {
    if (!_loaded) {
      return [notice("loading", "Reading…")];
    }
    return [
      if (_global)
        PageSection("about", "About you", [
          _field("name", "Name", _name, (v) => _name = v),
          _field(
            "dob",
            "Date of birth",
            _dob,
            (v) => _dob = v,
            prompt: "YYYY-MM-DD",
          ),
          _field("religion", "Religion", _religion, (v) => _religion = v),
          _field(
            "profession",
            "Profession",
            _profession,
            (v) => _profession = v,
          ),
        ], detail: "In every turn, in every project."),
      PageSection(
        "style",
        "How replies are worded",
        [
          ChoiceController<Tone>(
            part("tone", "Tone", hint: UiHint.dropdown),
            options: [
              for (final tone in _global ? Tone.values : Tone.values.skip(1))
                SettingOption(tone, tone.label),
            ],
            value: _tone,
            unsettable: !_global,
            inheritedLabel: _global ? null : _appTone.label,
            inherited: _global ? null : _appTone,
            onSet: (tone) async {
              _set(() => _tone = _global ? tone ?? Tone.none : tone);
              return null;
            },
          ),
          ToggleController(
            part(
              "citations",
              "Numbered references",
              hint: UiHint.toggle,
              description:
                  "Number the web pages a reply used and list them at the end",
            ),
            value: _citations,
            effective: _citations ?? _appCitations,
            unsettable: !_global,
            onSet: (on) async {
              _set(() => _citations = _global ? on ?? false : on);
              return null;
            },
          ),
        ],
        detail: _global
            ? "In every turn. A project can give its own answers."
            : "In place of the app's answer, in this project's chats.",
      ),
      PageSection(
        "instructions",
        "Instructions",
        [
          prompt(
            "instructions",
            "General instructions",
            text: _instructions,
            placeholder: _global
                ? "Standing rules for the agent, applied to every turn"
                : "Standing rules for this project's chats. Pull in a file "
                      "from the project workspace with a line like "
                      "@docs/style.md",
            onSet: (text) => _set(() => _instructions = text),
          ),
        ],
        detail: _global
            ? "Read by every user project's turns; the built-in projects run "
                  "on the app's own note. Stored at the root of your data "
                  "directory, where a conversation's commands cannot reach "
                  "them."
            : "The AGENTS.md at this project's workspace root, read by every "
                  "chat's turn in it.",
      ),
      if (isDesktop) ?_linkedSection(reader),
    ];
  }

  PageSection? _linkedSection(SettingReader reader) {
    final general = reader.read(appConfigProvider).globalInstructionsFile;
    final rows = [
      // The general instructions are a field when they are empty, not a file.
      if (!_missing.contains(general)) general,
      ..._linked,
    ];
    String nameOf(String path) =>
        path == general ? "General instructions" : p.basename(path);
    if (!_global && rows.isEmpty) return null;
    if (!_global) {
      return PageSection("files", "Instruction files", [
        for (final (i, path) in rows.indexed)
          ToggleController(
            part("file-$i", nameOf(path), hint: UiHint.toggle),
            description: _missing.contains(path) ? "Not found" : path,
            value: !_off.contains(path),
            effective: !_off.contains(path),
            onSet: (on) async {
              _set(
                () => _off = on ?? true
                    ? ({..._off}..remove(path))
                    : {..._off, path},
              );
              return null;
            },
          ),
      ], detail: "Your instructions, as this project's chats read them.");
    }
    return PageSection(
      "files",
      "Linked files",
      [
        CollectionController<String>(
          part("linked", "Linked files", hint: UiHint.info),
          items: _linked,
          removeLabel: "Unlink",
          emptyLabel: "No files linked.",
          describe: (path) => CollectionItem(
            nameOf(path),
            subtitle: path,
            error: _missing.contains(path) ? "Not found" : null,
            glyph: SettingGlyph.file,
            editable: false,
            takesImage: false,
            tap: "open",
            actions: const [
              ItemAction("up", "Move Up"),
              ItemAction("down", "Move Down"),
            ],
          ),
          onSet: (files) async => _set(() => _linked = files),
          act: (index, action) async {
            switch (action) {
              case "open":
                pages.open(
                  TextFileAppPage(
                    path: _linked[index],
                    name: nameOf(_linked[index]),
                    handsOff: false,
                  ),
                );
              case "up" when index > 0:
              case "down" when index < _linked.length - 1:
                final to = action == "up" ? index - 1 : index + 1;
                _set(() {
                  final path = _linked.removeAt(index);
                  _linked.insert(to, path);
                });
            }
            return null;
          },
        ),
        ActionController(
          part("add", "Link Files…", glyph: SettingGlyph.add),
          run: () async {
            final picked = await app
                .read(folderPickerProvider)
                .pickFiles(confirmLabel: "Add");
            final added = [
              for (final path in picked)
                if (!_linked.contains(path) && !p.equals(path, general)) path,
            ];
            if (added.isNotEmpty) _set(() => _linked = [..._linked, ...added]);
            return null;
          },
        ),
      ],
      detail:
          "Instruction files elsewhere on this computer, such as a CLAUDE.md, "
          "read after your general instructions in this order.",
    );
  }

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    ActionController(
      part("save", "Save", glyph: SettingGlyph.check),
      enabled: _loaded && !_saving,
      run: _save,
    ),
    ActionController(
      part("clear", "Clear", glyph: SettingGlyph.restart),
      enabled: _loaded && !_saving,
      run: () async {
        _set(() {
          _name = _dob = _religion = _profession = _instructions = "";
          if (_global) {
            _linked = [];
          } else {
            _off = {};
          }
          _tone = _global ? Tone.none : null;
          _citations = _global ? false : null;
        });
        return null;
      },
    ),
  ];

  String? _blank(String s) => s.trim().isEmpty ? null : s.trim();

  Future<SettingNotice?> _save() async {
    final dob = _dob.trim();
    if (dob.isNotEmpty && DateTime.tryParse(dob) == null) {
      return const SettingNotice("The date of birth is written YYYY-MM-DD.");
    }
    _saving = true;
    changed();
    final config = app.read(appConfigProvider);
    await _writeInstructions(_instructionsPath, _instructions);
    if (isDesktop) await _saveLinked(config.globalInstructionsFile);
    if (_global) {
      final profile = Profile(
        name: _blank(_name),
        dateOfBirth: _blank(_dob),
        religion: _blank(_religion),
        profession: _blank(_profession),
      );
      // One write of settings.json rather than three.
      await app
          .read(appSettingsProvider.notifier)
          .setReplyStyle(
            profile: profile.isEmpty ? null : profile,
            tone: _tone ?? Tone.none,
            citations: _citations ?? false,
          );
    } else {
      // Null stays null, so a Default inherits again.
      await app
          .read(projectSettingsProvider(project).notifier)
          .setReplyStyle(tone: _tone, citations: _citations);
    }
    _saving = false;
    _opened = _snapshot();
    pages.leave(this);
    return null;
  }

  Future<void> _saveLinked(String global) {
    final store = app.read(linkedInstructionsStoreProvider);
    final project = this.project;
    if (project == null) {
      return store.update((l) => l.withFiles(_linked, keep: global));
    }
    // Only what is still a row: a switch for a file unlinked since the page
    // opened would be a switch for nothing.
    return store.update(
      (l) => l.withOff(
        project,
        _off.where((p) => p == global || l.files.contains(p)),
      ),
    );
  }

  /// Through a rename: a turn reads the file between turns, and a half-write
  /// would be instructions half-followed. Empty deletes the file.
  Future<void> _writeInstructions(String path, String text) async {
    if (text.trim().isEmpty) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
      return;
    }
    await Directory(p.dirname(path)).create(recursive: true);
    await _write.write(path, text);
  }
}
