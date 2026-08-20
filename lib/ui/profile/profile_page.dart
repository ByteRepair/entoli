import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/profile.dart";
import "../../providers.dart";
import "../widgets/resettable_field.dart";

/// Edits the user's profile — the "About the user" block appended to the
/// system prompt. When [project] is null this is the app-level default, shown
/// from the sidebar; otherwise it is a project's override, reached from that
/// project's settings page.
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key, required this.project});

  final String? project;

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _prefs = TextEditingController();
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
    final Profile? profile;
    if (widget.project == null) {
      profile = ref.read(appSettingsProvider).profile;
    } else {
      profile = ref.read(projectSettingsProvider(widget.project)).profile;
    }
    if (profile != null) {
      _prefs.text = profile.preferencesPrompt ?? "";
      _name.text = profile.name ?? "";
      _dob.text = profile.dateOfBirth ?? "";
      _religion.text = profile.religion ?? "";
      _profession.text = profile.profession ?? "";
      _dobValue = _parseDate(profile.dateOfBirth);
    }
    if (mounted) setState(() => _loaded = true);
  }

  Profile _current() => Profile(
        preferencesPrompt: _blank(_prefs.text),
        name: _blank(_name.text),
        dateOfBirth: _blank(_dob.text),
        religion: _blank(_religion.text),
        profession: _blank(_profession.text),
      );

  String? _blank(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _save() async {
    setState(() => _saving = true);
    final profile = _current();
    final effective = profile.isEmpty ? null : profile;
    if (widget.project == null) {
      await ref.read(appSettingsProvider.notifier).setProfile(effective);
    } else {
      await ref.read(projectSettingsProvider(widget.project).notifier).setProfile(effective);
    }
    if (mounted) setState(() => _saving = false);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _clear() async {
    _prefs.clear();
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
    _prefs.dispose();
    _name.dispose();
    _dob.dispose();
    _religion.dispose();
    _profession.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project == null ? "Profile" : "Project profile"),
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
                if (widget.project != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      "Overrides the app-level profile for chats in this project. "
                      "Empty fields inherit from the app profile.",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                LabelledField(
                  label: "General preferences",
                  child: TextField(
                    controller: _prefs,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: "Custom instructions for the LLM, applied to every turn",
                    ),
                  ),
                ),
                LabelledField(
                  label: "Name",
                  child: TextField(
                    controller: _name,                  ),
                ),
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
                LabelledField(
                  label: "Religion",
                  child: TextField(
                    controller: _religion,                  ),
                ),
                LabelledField(
                  label: "Profession",
                  child: TextField(
                    controller: _profession,                  ),
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