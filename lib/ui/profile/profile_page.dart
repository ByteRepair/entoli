import "dart:io";

import "package:file_selector/file_selector.dart" show openFiles;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/platform/form_factor.dart";
import "../../domain/documents.dart" show RenameWriter;
import "../../domain/profile.dart";
import "../../domain/tone.dart";
import "../../providers.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart" show mutedParagraph;
import "../widgets/text_file_page.dart";
import "linked_instructions.dart";

/// Edits what a turn knows about the user. With no [project] this is the
/// app-level page, shown from the sidebar: the identity fields, which the
/// prompt renders as "About the user", and the user's global instructions —
/// the AGENTS.md at the data dir's root that every user project's turns read;
/// a built-in project runs on a note the app ships instead. With a [project]
/// it is that project's page, reached from the project settings: the
/// AGENTS.md at its workspace root, the file its chats' turns read, and
/// nothing else — a chat would contain all the context it needs, and the
/// identity fields are the user's, not a project's.
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key, required this.project});

  final String? project;

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _instructions = TextEditingController();
  final _name = TextEditingController();
  final _dob = TextEditingController();
  final _religion = TextEditingController();
  final _profession = TextEditingController();

  /// The one writer of the instructions file — created on the first use of
  /// the page's config, so two overlapping saves queue behind each other
  /// rather than racing two fixed rename temps.
  RenameWriter? _write;

  RenameWriter _writerOf(AppConfig config) =>
      _write ??= RenameWriter();

  DateTime? _dobValue;
  Tone? _tone;
  bool? _citations;
  bool _loaded = false;
  bool _saving = false;

  /// The linked instruction files, in reading order — the app page's list.
  List<String> _linked = [];

  /// Of the global AGENTS.md and [_linked], what this project switched off.
  Set<String> _off = {};

  /// Which of them are not on disk, said on the row rather than dropped from
  /// it: a file on a drive not mounted yet is still meant to be there.
  Set<String> _missing = {};

  /// The app's resolved answers, read once for the project page's `Default`
  /// entries to name.
  Tone _appTone = Tone.none;
  bool _appCitations = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = ref.read(appConfigProvider);
    final path = _instructionsPath(config);
    try {
      final file = File(path);
      if (file.existsSync()) _instructions.text = await file.readAsString();
    } catch (_) {
      // A file that will not read is shown as empty; saving overwrites it.
    }
    // Linking is by path, which only a desktop's picker hands back: a phone's
    // gives a copy.
    if (isDesktop) {
      final linked = await ref.read(linkedInstructionsStoreProvider).load();
      _linked = [...linked.files];
      _off = {...?linked.off[widget.project]};
      _missing =
          await _missingOf([config.globalInstructionsFile, ..._linked]);
    }
    if (widget.project == null) {
      final settings = ref.read(appSettingsProvider);
      final profile = settings.profile;
      if (profile != null) {
        _name.text = profile.name ?? "";
        _dob.text = profile.dateOfBirth ?? "";
        _religion.text = profile.religion ?? "";
        _profession.text = profile.profession ?? "";
        _dobValue = _parseDate(profile.dateOfBirth);
      }
      _tone = settings.tone;
      _citations = settings.citations;
    } else {
      final project = ref.read(projectSettingsProvider(widget.project));
      _appTone = ref.read(appSettingsProvider).tone;
      _appCitations = ref.read(appSettingsProvider).citations;
      _tone = project.tone;
      _citations = project.citations;
    }
    if (mounted) setState(() => _loaded = true);
  }

  String _instructionsPath(AppConfig config) =>
      widget.project == null
          ? config.globalInstructionsFile
          : config.projectInstructionsFile(project: widget.project);

  /// Together rather than in turn: a path on a stalled mount should cost the
  /// page its own wait, not everyone's after it.
  Future<Set<String>> _missingOf(List<String> paths) async {
    // ignore: avoid_slow_async_io
    final exists = await Future.wait(paths.map((p) => File(p).exists()));
    return {for (final (i, path) in paths.indexed) if (!exists[i]) path};
  }

  String _nameOf(String path) => p.basename(path);

  Future<void> _openFile(String path, String name) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TextFilePage(path: path, name: name, popsBinary: false),
    ));
  }

  Future<void> _addFiles() async {
    final picked = await openFiles(confirmButtonText: "Add");
    final config = ref.read(appConfigProvider);
    final added = [
      for (final file in picked)
        if (!_linked.contains(file.path) &&
            !p.equals(file.path, config.globalInstructionsFile))
          file.path,
    ];
    if (added.isEmpty || !mounted) return;
    setState(() => _linked = [..._linked, ...added]);
  }

  void _reorder(int from, int to) => setState(() {
        final path = _linked.removeAt(from);
        _linked.insert(to, path);
      });

  Future<void> _saveLinked(AppConfig config) {
    final store = ref.read(linkedInstructionsStoreProvider);
    final project = widget.project;
    final global = config.globalInstructionsFile;
    if (project == null) {
      return store.update((l) => l.withFiles(_linked, keep: global));
    }
    // Only what is still a row: a switch for a file unlinked since the page
    // opened would be a switch for nothing.
    return store.update((l) => l.withOff(
        project, _off.where((p) => p == global || l.files.contains(p))));
  }

  Profile _profile() => Profile(
        name: _blank(_name.text),
        dateOfBirth: _blank(_dob.text),
        religion: _blank(_religion.text),
        profession: _blank(_profession.text),
      );

  String? _blank(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = ref.read(appConfigProvider);
    await _writeInstructions(config, _instructionsPath(config), _instructions.text);
    if (isDesktop) await _saveLinked(config);
    if (widget.project == null) {
      final profile = _profile();
      // One write of settings.json: three separate setters would be three
      // re-encodes and renames of the one file, the first two superseded.
      await ref.read(appSettingsProvider.notifier).setReplyStyle(
            profile: profile.isEmpty ? null : profile,
            tone: _tone ?? Tone.none,
            citations: _citations ?? false,
          );
    } else {
      // One write of project.json. Null stays null, so a field left on
      // Default inherits again rather than pinning what it inherited.
      await ref
          .read(projectSettingsProvider(widget.project).notifier)
          .setReplyStyle(tone: _tone, citations: _citations);
    }
    if (mounted) setState(() => _saving = false);
    if (mounted) Navigator.of(context).pop();
  }

  /// Through a rename: a turn reads the file between turns, and a truncated
  /// half-write would be instructions the model half-follows. An empty field
  /// deletes the file rather than leaving an empty one behind.
  Future<void> _writeInstructions(
      AppConfig config, String path, String text) async {
    if (text.trim().isEmpty) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
      return;
    }
    await Directory(p.dirname(path)).create(recursive: true);
    await _writerOf(config).write(path, text);
  }

  Future<void> _clear() async {
    _instructions.clear();
    _name.clear();
    _dob.clear();
    _religion.clear();
    _profession.clear();
    setState(() {
      if (widget.project == null) {
        _linked = [];
      } else {
        _off = {};
      }
      _dobValue = null;
      _tone = widget.project == null ? Tone.none : null;
      _citations = widget.project == null ? false : null;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dobValue ?? DateTime(now.year - 30),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() {
      _dobValue = picked;
      _dob.text = _formatDate(picked);
    });
  }

  /// The app page lists the linked files, read after the general
  /// instructions; a project's page switches each of the user's files.
  List<Widget> _linkedSection(bool global) {
    final generalPath = ref.read(appConfigProvider).globalInstructionsFile;
    final rows = [
      // The general instructions are a field when they are empty, not a file.
      if (!_missing.contains(generalPath)) (generalPath, "General instructions"),
      for (final path in _linked) (path, _nameOf(path)),
    ];
    if (!global && rows.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: mutedParagraph(
          context,
          global
              ? "Instruction files elsewhere on this computer, such as a "
                  "CLAUDE.md, read after your general instructions in this "
                  "order. Hold a row to move it."
              : "Your instructions, as this project's chats read them.",
        ),
      ),
      if (global)
        LinkedFileList(
          files: _linked,
          missing: _missing,
          nameOf: _nameOf,
          onOpen: _openFile,
          onRemove: (path) =>
              setState(() => _linked = [..._linked]..remove(path)),
          onReorder: _reorder,
          onAdd: _addFiles,
        )
      else
        InstructionFileSwitches(
          rows: rows,
          off: _off,
          missing: _missing,
          onOpen: _openFile,
          onChanged: (path, on) => setState(
              () => _off = on ? ({..._off}..remove(path)) : {..._off, path}),
        ),
    ];
  }

  @override
  void dispose() {
    _instructions.dispose();
    _name.dispose();
    _dob.dispose();
    _religion.dispose();
    _profession.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final global = widget.project == null;
    // The reply-style rows: values at app level, overrides at a project's.
    // The dropdown's own Default entry and reset button are the inherit
    // affordance a project level needs, and nothing carries one here.
    final toneRow = global
        ? LabelledField(
            label: "Tone",
            child: DropdownButtonFormField<Tone>(
              initialValue: _tone ?? Tone.none,
              items: [
                for (final tone in Tone.values)
                  DropdownMenuItem(value: tone, child: Text(tone.label)),
              ],
              onChanged: (value) =>
                  setState(() => _tone = value ?? Tone.none),
            ),
          )
        : InheritableDropdown<Tone>(
            label: "Tone",
            value: _tone,
            inherited: _appTone.label,
            options: {for (final tone in Tone.values.skip(1)) tone: tone.label},
            onChanged: (value) => setState(() => _tone = value),
          );
    final citationsRow = global
        ? SwitchListTile(
            title: const Text("Numbered references"),
            subtitle: const Text(
                "Number the web pages a reply used and list them at the end"),
            value: _citations ?? false,
            onChanged: (value) => setState(() => _citations = value),
          )
        : InheritableSwitch(
            title: "Numbered references",
            subtitle:
                "Number the web pages a reply used and list them at the end",
            value: _citations,
            inherited: _appCitations,
            onChanged: (value) => setState(() => _citations = value),
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(global ? "Profile" : "Project instructions"),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: "Clear",
            onPressed: _loaded && !_saving ? _clear : null,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: "Save",
            onPressed: _loaded && !_saving ? _save : null,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (global)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      "About you, in every turn, in every project.",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                if (global)
                  LabelledField(
                    label: "Name",
                    child: TextField(
                        controller: _name),
                  ),
                if (global)
                  LabelledField(
                    label: "Date of birth",
                    child: TextField(
                      controller: _dob,
                      readOnly: true,
                      decoration: InputDecoration(
                        hintText: "Not set",
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.calendar_today),
                          onPressed: _pickDate,
                          tooltip: "Pick date",
                        ),
                      ),
                      onTap: _pickDate,
                    ),
                  ),
                if (global)
                  LabelledField(
                    label: "Religion",
                    child: TextField(controller: _religion),
                  ),
                if (global)
                  LabelledField(
                    label: "Profession",
                    child: TextField(controller: _profession),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    global
                        ? "How replies are worded, in every turn. A project "
                            "can give its own answers below."
                        : "How this project's replies are worded, in place of "
                            "the app's answer.",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                toneRow,
                citationsRow,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                  global
                      ? "Your global instructions, read by every user project's "
                          "turns; the built-in projects run on the app's own "
                          "note. Stored at the root of your data directory, "
                          "where a conversation's commands cannot reach them."
                      : "The AGENTS.md at this project's workspace root, read by "
                          "every chat's turn in it.",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                LabelledField(
                  label: "General instructions",
                  child: TextField(
                    controller: _instructions,
                    maxLines: 8,
                    // Only the project's file follows `@path`: the global
                    // one's are left as text, so no example there.
                    decoration: InputDecoration(
                      hintText: global
                          ? "Standing rules for the agent, applied to every turn"
                          : "Standing rules for this project's chats\n\n"
                              "Pull in a file from the project workspace with "
                              "a line like:\n@docs/style.md",
                    ),
                  ),
                ),
                if (isDesktop) ..._linkedSection(global),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

DateTime? _parseDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso);
}

String _formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return "${d.year}-${two(d.month)}-${two(d.day)}";
}
