import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/config.dart";
import "../../domain/documents.dart" show writingSuffix;
import "../../domain/profile.dart";
import "../../providers.dart";
import "../widgets/resettable_field.dart";

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

  DateTime? _dobValue;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = ref.read(appConfigProvider);
    final path = _instructionsPath(config);
    try {
      final file = config.fs.file(path);
      if (await file.exists()) _instructions.text = await file.readAsString();
    } catch (_) {
      // A file that will not read is shown as empty; saving overwrites it.
    }
    if (widget.project == null) {
      final profile = ref.read(appSettingsProvider).profile;
      if (profile != null) {
        _name.text = profile.name ?? "";
        _dob.text = profile.dateOfBirth ?? "";
        _religion.text = profile.religion ?? "";
        _profession.text = profile.profession ?? "";
        _dobValue = _parseDate(profile.dateOfBirth);
      }
    }
    if (mounted) setState(() => _loaded = true);
  }

  String _instructionsPath(AppConfig config) =>
      widget.project == null
          ? config.globalInstructionsFile
          : config.fs.path.join(
              config.projectWorkspaceDir(project: widget.project),
              "AGENTS.md",
            );

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
    if (widget.project == null) {
      final profile = _profile();
      await ref
          .read(appSettingsProvider.notifier)
          .setProfile(profile.isEmpty ? null : profile);
    }
    if (mounted) setState(() => _saving = false);
    if (mounted) Navigator.of(context).pop();
  }

  /// Through a rename: a turn reads the file between turns, and a truncated
  /// half-write would be instructions the model half-follows.
  Future<void> _writeInstructions(
      AppConfig config, String path, String text) async {
    final fs = config.fs;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      final file = fs.file(path);
      if (await file.exists()) await file.delete();
      return;
    }
    await fs.directory(fs.path.dirname(path)).create(recursive: true);
    final temp = fs.file("$path$writingSuffix");
    await temp.writeAsString(text);
    await temp.rename(path);
  }

  Future<void> _clear() async {
    _instructions.clear();
    _name.clear();
    _dob.clear();
    _religion.clear();
    _profession.clear();
    setState(() => _dobValue = null);
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
                    decoration: const InputDecoration(
                      hintText:
                          "Standing rules for the agent, applied to every turn",
                    ),
                  ),
                ),
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
