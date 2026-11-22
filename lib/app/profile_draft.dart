import "dart:convert";
import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../core/log.dart";
import "../core/platform/form_factor.dart";
import "../domain/documents.dart" show RenameWriter;
import "../domain/profile.dart";
import "../domain/tone.dart";
import "../providers.dart";

/// What a turn knows about the user, as the profile page edits it. With no
/// [project] it is the app's: the identity fields, how replies are worded,
/// the global instructions and, on a desktop, the instruction files linked
/// from elsewhere. With a [project] it is that project's: the AGENTS.md at
/// its workspace root, its own answers for how replies are worded, and which
/// of the user's files it reads. Saved whole by [ProfileEditor.save].
class ProfileDraft {
  ProfileDraft._(this.project, this.generalFile);

  final String? project;

  /// The global AGENTS.md, which a project's page lists among the files.
  final String generalFile;

  bool get global => project == null;

  String instructions = "";
  String name = "";
  String dob = "";
  String religion = "";
  String profession = "";
  Tone? tone;
  bool? citations;

  /// The linked instruction files, in reading order, and which of them and
  /// the general instructions the project switched off; which are not on
  /// disk, said on the row rather than dropped from it, since a file on a
  /// drive not mounted yet is still meant to be there.
  List<String> linked = [];
  Set<String> off = {};
  Set<String> missing = {};

  /// The app's answers, which a project's Default entries name.
  Tone appTone = Tone.none;
  bool appCitations = false;

  late String _opened;

  /// Everything a save writes, as one comparable value.
  String _snapshot() => jsonEncode([
    instructions,
    name,
    dob,
    religion,
    profession,
    tone?.name,
    citations,
    linked,
    off.toList()..sort(),
  ]);

  bool get edited => _snapshot() != _opened;

  /// What a project's page switches: the general instructions where they
  /// are a file, then the linked ones.
  List<String> get instructionFiles => [
    if (!missing.contains(generalFile)) generalFile,
    ...linked,
  ];

  String nameOf(String path) =>
      path == generalFile ? "General instructions" : p.basename(path);

  void clear() {
    name = dob = religion = profession = instructions = "";
    if (global) {
      linked = [];
    } else {
      off = {};
    }
    tone = global ? Tone.none : null;
    citations = global ? false : null;
  }

  /// [picked] after the files already linked, the general instructions and
  /// repeats left out.
  void link(List<String> picked) => linked = [
    ...linked,
    for (final path in picked)
      if (!linked.contains(path) && !p.equals(path, generalFile)) path,
  ];

  void unlink(String path) => linked = [...linked]..remove(path);

  void move(int from, int to) {
    final path = linked.removeAt(from);
    linked.insert(to, path);
  }

  void switchFile(String path, bool on) =>
      off = on ? ({...off}..remove(path)) : {...off, path};
}

/// Loads and saves a [ProfileDraft].
class ProfileEditor {
  ProfileEditor(this._ref);

  final Ref _ref;

  /// One writer of the instructions files, so two overlapping saves queue.
  final _write = RenameWriter();

  String _instructionsPath(String? project) {
    final config = _ref.read(appConfigProvider);
    return project == null
        ? config.globalInstructionsFile
        : config.projectInstructionsFile(project: project);
  }

  Future<ProfileDraft> load({String? project}) async {
    final config = _ref.read(appConfigProvider);
    final draft = ProfileDraft._(project, config.globalInstructionsFile);
    try {
      final file = File(_instructionsPath(project));
      if (file.existsSync()) draft.instructions = await file.readAsString();
    } catch (e) {
      // A file that will not read is shown as empty; saving overwrites it.
      logFailure("profile", "could not read the instructions", e);
    }
    // Linking is by path, which only a desktop's picker hands back: a
    // phone's gives a copy.
    if (isDesktop) {
      final linked = await _ref.read(linkedInstructionsStoreProvider).load();
      draft.linked = [...linked.files];
      draft.off = {...?linked.off[project]};
      draft.missing = await _missingOf([
        config.globalInstructionsFile,
        ...draft.linked,
      ]);
    }
    final settings = _ref.read(appSettingsProvider);
    if (project == null) {
      final profile = settings.profile;
      draft
        ..name = profile?.name ?? ""
        ..dob = profile?.dateOfBirth ?? ""
        ..religion = profile?.religion ?? ""
        ..profession = profile?.profession ?? ""
        ..tone = settings.tone
        ..citations = settings.citations;
    } else {
      final own = _ref.read(projectSettingsProvider(project));
      draft
        ..appTone = settings.tone
        ..appCitations = settings.citations
        ..tone = own.tone
        ..citations = own.citations;
    }
    draft._opened = draft._snapshot();
    return draft;
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

  /// Null where it was saved, else what to say.
  Future<String?> save(ProfileDraft draft) async {
    final dob = draft.dob.trim();
    if (dob.isNotEmpty && DateTime.tryParse(dob) == null) {
      return "The date of birth is written YYYY-MM-DD.";
    }
    await _writeInstructions(
      _instructionsPath(draft.project),
      draft.instructions,
    );
    if (isDesktop) await _saveLinked(draft);
    if (draft.global) {
      final profile = Profile(
        name: _blank(draft.name),
        dateOfBirth: _blank(draft.dob),
        religion: _blank(draft.religion),
        profession: _blank(draft.profession),
      );
      // One write of settings.json rather than three.
      await _ref
          .read(appSettingsProvider.notifier)
          .setReplyStyle(
            profile: profile.isEmpty ? null : profile,
            tone: draft.tone ?? Tone.none,
            citations: draft.citations ?? false,
          );
    } else {
      // Null stays null, so a Default inherits again.
      await _ref
          .read(projectSettingsProvider(draft.project).notifier)
          .setReplyStyle(tone: draft.tone, citations: draft.citations);
    }
    draft._opened = draft._snapshot();
    return null;
  }

  String? _blank(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _saveLinked(ProfileDraft draft) {
    final store = _ref.read(linkedInstructionsStoreProvider);
    final project = draft.project;
    final global = draft.generalFile;
    if (project == null) {
      return store.update((l) => l.withFiles(draft.linked, keep: global));
    }
    // Only what is still a row: a switch for a file unlinked since the page
    // opened would be a switch for nothing.
    return store.update(
      (l) => l.withOff(
        project,
        draft.off.where((p) => p == global || l.files.contains(p)),
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

final profileEditorProvider = Provider(ProfileEditor.new);
