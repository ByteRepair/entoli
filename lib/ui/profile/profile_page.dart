import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/tone.dart";
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/dialogs.dart";
import "package:entoli_core/view/widgets/discard_guard.dart";
import "package:entoli_core/view/widgets/page_bar.dart";
import "package:entoli_core/view/widgets/text_file_page.dart";

import "../../app/profile_draft.dart";
import "../../core/platform/form_factor.dart";
import "../../providers.dart";
import "../widgets/prompt_field.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "linked_instructions.dart";

/// Open the profile: the app's with no [project] (the sidebar's tile and the
/// app menu), else that project's instructions.
Future<void> openProfile(BuildContext context, {String? project}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ProfilePage(project: project)),
    );

/// Edits a [ProfileDraft]: what a turn knows about the user, or with a
/// [project] that project's instructions. Saved whole by the bar's tick.
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key, this.project});

  final String? project;

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  ProfileDraft? _draft;
  Object? _failed;
  final _busy = ValueNotifier(false);
  final _name = TextEditingController();
  final _dob = TextEditingController();
  final _religion = TextEditingController();
  final _profession = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _busy.dispose();
    _name.dispose();
    _dob.dispose();
    _religion.dispose();
    _profession.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ProfileDraft draft;
    try {
      draft = await ref
          .read(profileEditorProvider)
          .load(project: widget.project);
    } catch (e) {
      logFailure("profile", "could not read the profile", e);
      if (mounted) setState(() => _failed = e);
      return;
    }
    if (!mounted) return;
    _name.text = draft.name;
    _dob.text = draft.dob;
    _religion.text = draft.religion;
    _profession.text = draft.profession;
    setState(() => _draft = draft);
  }

  void _edit(void Function(ProfileDraft draft) change) =>
      setState(() => change(_draft!));

  Future<void> _save() => whileBusy(context, _busy, () async {
    final refusal = await ref.read(profileEditorProvider).save(_draft!);
    if (!mounted) return;
    if (refusal != null) return say(context, refusal);
    Navigator.of(context).pop();
  });

  void _clear() {
    _name.clear();
    _dob.clear();
    _religion.clear();
    _profession.clear();
    _edit((d) => d.clear());
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final first = DateTime(1900);
    // A date typed by hand can be outside what the picker offers, which it
    // asserts against.
    final typed = DateTime.tryParse(_dob.text.trim());
    final initial = typed == null || typed.isBefore(first) || typed.isAfter(now)
        ? DateTime(now.year - 30)
        : typed;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    String two(int n) => n.toString().padLeft(2, "0");
    _dob.text = "${picked.year}-${two(picked.month)}-${two(picked.day)}";
    _draft!.dob = _dob.text;
  }

  Future<void> _link() => whileBusy(context, _busy, () async {
    final picked = await ref
        .read(folderPickerProvider)
        .pickFiles(confirmLabel: "Add");
    if (mounted) _edit((d) => d.link(picked));
  });

  void _open(String path) => openTextFile(context, path, _draft!.nameOf(path));

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final global = widget.project == null;
    return DiscardGuard(
      edited: () => _draft?.edited ?? false,
      child: Scaffold(
        appBar: PageBar(
          title: global ? "Profile" : "Project instructions",
          actions: [
            PageAction.icon(
              icon: Icons.restart_alt,
              label: "Clear",
              onPressed: draft == null ? null : _clear,
            ),
            PageAction.confirm(onPressed: draft == null ? null : _save),
          ],
        ),
        body: Column(
          children: [
            BusyBar(_busy),
            Expanded(
              child: draft == null
                  ? Center(
                      child: _failed == null
                          ? const CircularProgressIndicator()
                          : Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text("Could not read the profile: $_failed"),
                                  const SizedBox(height: 12),
                                  TextButton(
                                    onPressed: () {
                                      setState(() => _failed = null);
                                      _load();
                                    },
                                    child: const Text("Try again"),
                                  ),
                                ],
                              ),
                            ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        if (global) ..._about(draft),
                        ..._style(draft),
                        ..._instructions(draft),
                        if (isDesktop) ..._files(draft),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    void Function(String) set, {
    String hint = "Not set",
    Widget? suffix,
  }) => LabelledField(
    label: label,
    child: TextField(
      controller: controller,
      decoration: InputDecoration(hintText: hint, suffixIcon: suffix),
      onChanged: set,
    ),
  );

  List<Widget> _about(ProfileDraft draft) => [
    const SectionHeader(
      "About you",
      description: "In every turn, in every project.",
    ),
    _field("Name", _name, (v) => draft.name = v),
    _field(
      "Date of birth",
      _dob,
      (v) => draft.dob = v,
      hint: "YYYY-MM-DD",
      suffix: IconButton(
        icon: const Icon(Icons.calendar_today),
        tooltip: "Pick date",
        onPressed: _pickDate,
      ),
    ),
    _field("Religion", _religion, (v) => draft.religion = v),
    _field("Profession", _profession, (v) => draft.profession = v),
  ];

  List<Widget> _style(ProfileDraft draft) {
    const references = "Numbered references";
    const referencesDetail =
        "Number the web pages a reply used and list them at the end";
    return [
      SectionHeader(
        "How replies are worded",
        description: draft.global
            ? "In every turn. A project can give its own answers."
            : "In place of the app's answer, in this project's chats.",
      ),
      if (draft.global) ...[
        LabelledField(
          label: "Tone",
          child: DropdownButtonFormField<Tone>(
            initialValue: draft.tone ?? Tone.none,
            items: [
              for (final tone in Tone.values)
                DropdownMenuItem(value: tone, child: Text(tone.label)),
            ],
            onChanged: (tone) => _edit((d) => d.tone = tone ?? Tone.none),
          ),
        ),
        SwitchListTile(
          title: const Text(references),
          subtitle: const Text(referencesDetail),
          value: draft.citations ?? false,
          onChanged: (on) => _edit((d) => d.citations = on),
        ),
      ] else ...[
        InheritableDropdown<Tone>(
          label: "Tone",
          value: draft.tone,
          inherited: draft.appTone.label,
          options: {for (final tone in Tone.values.skip(1)) tone: tone.label},
          onChanged: (tone) => _edit((d) => d.tone = tone),
        ),
        InheritableSwitch(
          title: references,
          subtitle: referencesDetail,
          value: draft.citations,
          inherited: draft.appCitations,
          onChanged: (on) => _edit((d) => d.citations = on),
        ),
      ],
    ];
  }

  List<Widget> _instructions(ProfileDraft draft) => [
    SectionHeader(
      "Instructions",
      description: draft.global
          ? "Read by every user project's turns; the built-in projects run "
                "on the app's own note. Stored at the root of your data "
                "directory, where a conversation's commands cannot reach them."
          : "The AGENTS.md at this project's workspace root, read by every "
                "chat's turn in it.",
    ),
    // No completions: an `@` here is a file to pull in, not an agent.
    PromptField(
      label: "General instructions",
      value: draft.instructions,
      completions: false,
      // Only the project's file follows `@path`, so no example on the app's.
      hint: draft.global
          ? "Standing rules for the agent, applied to every turn"
          : "Standing rules for this project's chats\n\n"
                "Pull in a file from the project workspace with a line "
                "like:\n@docs/style.md",
      onChanged: (text) => _edit((d) => d.instructions = text),
    ),
  ];

  List<Widget> _files(ProfileDraft draft) {
    if (draft.global) {
      return [
        const SectionHeader(
          "Linked files",
          description:
              "Instruction files elsewhere on this computer, such as a "
              "CLAUDE.md, read after your general instructions in this order. "
              "Hold a row to move it.",
        ),
        LinkedFileList(
          files: draft.linked,
          missing: draft.missing,
          nameOf: draft.nameOf,
          onOpen: _open,
          onRemove: (path) => _edit((d) => d.unlink(path)),
          onReorder: (from, to) => _edit((d) => d.move(from, to)),
          onAdd: _link,
        ),
      ];
    }
    final rows = draft.instructionFiles;
    if (rows.isEmpty) return const [];
    return [
      const SectionHeader(
        "Instruction files",
        description: "Your instructions, as this project's chats read them.",
      ),
      for (final path in rows)
        InstructionFileTile(
          path: path,
          name: draft.nameOf(path),
          missing: draft.missing.contains(path),
          onTap: () => _open(path),
          trailing: Switch(
            value: !draft.off.contains(path),
            onChanged: (on) => _edit((d) => d.switchFile(path, on)),
          ),
        ),
    ];
  }
}
