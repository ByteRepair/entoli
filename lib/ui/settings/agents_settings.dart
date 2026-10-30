import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:file_selector/file_selector.dart";
import "package:flutter/foundation.dart" show setEquals;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../core/platform/platform.dart" as platform;
import "../../data/builtin/tools/agent_tool.dart";
import "../../data/builtin/tools/registry.dart";
import "../../data/prompts/agent_pictures.dart";
import "../../data/prompts/prompt_export.dart";
import "../../data/prompts/skill_import.dart";
import "../../domain/agent_definition.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show promptsDirUserWritable;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/agent_picture.dart";
import "../widgets/busy.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

const _agentFiles = XTypeGroup(
  label: "Agent",
  extensions: ["md"],
  mimeTypes: ["text/markdown"],
  uniformTypeIdentifiers: ["net.daringfireball.markdown"],
);

/// The agents a message can address by name. The list is the library's; the
/// page's own question is where each one came from — a bundled agent is
/// Entoli's and not editable, the user's are written here and are. An agent is
/// one flat `.md` file (a system prompt with `description` frontmatter), so it
/// is written in-app rather than imported the way a skill's directory is.
///
/// Add and Import agent are the footer, fixed to the bottom of the page so
/// they do not scroll with the list — the same shape the skills page pins its
/// import flow in. Export rides every row, wherever the entry it names came
/// from.
///
/// [project] is whose set the page reads and whose directory it writes: null
/// is the app-level page and the default project, a name is that project's
/// settings page. A built-in project's page is view-only — it shows the
/// entries its directory, the default's and the bundled presets make up, with
/// nothing to change any of them, since a turn in it answers to the spec.
class AgentsSection extends ConsumerStatefulWidget {
  const AgentsSection({super.key, this.project, this.device});

  final String? project;

  /// The paired device [project] is on, null for this one. Its list is
  /// that device's, shown and not changed here: the files are there.
  final String? device;

  @override
  ConsumerState<AgentsSection> createState() => _AgentsSectionState();
}

class _AgentsSectionState extends ConsumerState<AgentsSection> {
  final _busy = ValueNotifier(false);

  /// Which agents live in [project]'s own directory. Null while the first
  /// scan is out, the same as skills: the library knows what is loaded, not
  /// where each one came from. Every other name on the list is inherited or
  /// bundled.
  Set<String>? _userAgents;

  bool get _writable => _local && promptsDirUserWritable(widget.project);

  bool get _local => widget.device == null;

  @override
  void initState() {
    super.initState();
    if (_local) _scan();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final config = ref.read(appConfigProvider);
    final names = <String>{};
    final dir = Directory(config.promptsDir(CompletionKind.agent, project: widget.project));
    if (dir.existsSync()) {
      await for (final entity in dir.list()) {
        if (entity is File && p.extension(entity.path) == ".md") {
          names.add(p.basenameWithoutExtension(entity.path));
        }
      }
    }
    if (mounted) setState(() => _userAgents = names);
  }

  Future<void> _add() async {
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
          builder: (_) => AgentEditorPage(
              initial: AgentDefinition.main, isNew: true, project: widget.project)),
    );
    if (result == null || !mounted) return;
    await _save(result, previous: null);
  }

  Future<void> _edit(PromptDocument agent) async {
    final config = ref.read(appConfigProvider);
    // This project's own picture, not the tiers' answer: the editor edits
    // the level it writes. A picture inherited from the default project's
    // directory shows on the rows but not here — picking one sets this
    // project's, and a remove takes this project's away, where "removed on
    // save" would otherwise leave the inherited one on screen.
    final file =
        File(agentPicturePath(config, agent.name, project: widget.project));
    final bytes = file.existsSync() ? await file.readAsBytes() : null;
    if (!mounted) return;
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          initial: AgentDefinition.of(agent),
          isNew: false,
          project: widget.project,
          initialPicture: bytes,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _save(result, previous: agent.name);
  }

  /// [previous] is the name the edit started from — null on add, the agent's
  /// own on edit. A different name on the way out is a rename: the new file is
  /// written before the old one is deleted, so a failure halfway leaves the
  /// agent where it was, or in both copies if only the delete failed. A
  /// mention already written into a conversation keeps the meaning it was
  /// recorded with; a new mention of the old name is the only thing a rename
  /// loses. The collision that stops a rename is the editor's to show — it is
  /// the layer the field is on — so only an add confirms here.
  Future<void> _save(AgentEdit edit, {required String? previous}) async {
    final name = edit.agent.name;
    if (!isFolderName(name)) {
      _say("That name cannot be a file name.");
      return;
    }
    if (previous == null && !await _mayReplace(name, "Saving")) return;
    await _write(
      name,
      edit.agent.toSource(),
      "Saved $name.",
      removes: previous,
      picture: edit.picture,
      removePicture: edit.removePicture,
    );
  }

  /// The one write an agent page makes — editor save or import alike — with
  /// the library reload and directory rescan that land it on the list.
  /// [removes] names the file a rename takes away, written over first so a
  /// failure halfway leaves the agent where it was. [picture] writes a
  /// `<name>.png` beside the `.md`, and moves the old name's with a rename —
  /// the picture follows the agent; [removePicture] takes it away. The create
  /// is load-bearing: `writeAsString` does not make parents.
  Future<void> _write(
    String name,
    String source,
    String said, {
    String? removes,
    Uint8List? picture,
    bool removePicture = false,
  }) =>
      _guard(() async {
        final config = ref.read(appConfigProvider);
        final renames = removes != null && removes != name;
        await platform.readOnlyDirs
            .of(config.promptsDir(CompletionKind.agent, project: widget.project))
            .write(() async {
            final file =
                File(agentFilePath(config, name, project: widget.project));
            await file.create(recursive: true);
            await file.writeAsString(source);
            if (renames) {
              await File(agentFilePath(config, removes, project: widget.project))
                  .delete();
            }
            final image =
                File(agentPicturePath(config, name, project: widget.project));
            if (removePicture) {
              if (image.existsSync()) await image.delete();
            } else if (picture != null) {
              await image.writeAsBytes(picture);
            } else if (renames) {
              // A rename: the old picture moves with the agent, standing over
              // it where both were set — rename over an existing file is fine.
              final oldImage = File(agentPicturePath(config, removes, project: widget.project));
              if (oldImage.existsSync()) await oldImage.rename(image.path);
            }
          });
        await _reload(widget.project);
        await _scan();
        _invalidatePicture(name);
        if (renames) _invalidatePicture(removes);
        _say(said);
      });

  Future<void> _delete(PromptDocument agent) async {
    final confirmed = await confirm(
      context,
      title: "Remove ${agent.name}?",
      message: "The agent is deleted. A bundled agent of the same name, if "
          "there is one, is back the next time the library loads.",
      confirmLabel: "Remove",
      destructive: true,
    );
    if (!confirmed) return;

    await _guard(() async {
      final config = ref.read(appConfigProvider);
      await platform.readOnlyDirs
          .of(config.promptsDir(CompletionKind.agent, project: widget.project))
          .write(() async {
          await File(agentFilePath(config, agent.name, project: widget.project))
              .delete();
          final image =
              File(agentPicturePath(config, agent.name, project: widget.project));
          if (image.existsSync()) await image.delete();
        });
      await _reload(widget.project);
      await _scan();
      _invalidatePicture(agent.name);
      _say("Removed ${agent.name}.");
    });
  }

  /// An imported `.md` lands under its file's name, the way an editor save
  /// names one — the name is the file name, and an editor pass before it
  /// would be a second way to make the two diverge. A body with nothing in
  /// it is refused: an agent the composer completes to nothing is a mention
  /// that does nothing.
  Future<void> _import() async {
    final file = await openFile(acceptedTypeGroups: const [_agentFiles]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    final source = utf8.decode(bytes, allowMalformed: true);
    final document = PromptDocument.parse(CompletionKind.agent, "", source);
    if (document.body.isEmpty) {
      _say("That file cannot be imported: there is no prompt in it.");
      return;
    }
    final name =
        p.basenameWithoutExtension(file.name);
    if (!isFolderName(name)) {
      _say("That file cannot be imported: its name cannot be a file name.");
      return;
    }
    if (!await _mayReplace(name, "Importing")) return;
    await _write(name, source, "Imported $name.");
  }

  /// False where [name] is already in this project's directory and the user
  /// would rather keep it, or the page went away while asking.
  Future<bool> _mayReplace(String name, String doing) async {
    final config = ref.read(appConfigProvider);
    final exists = await File(agentFilePath(config, name, project: widget.project))
        .exists();
    if (!mounted) return false;
    return !exists ||
        await confirm(
          context,
          title: "Replace $name?",
          message: "An agent with that name is already installed. $doing "
              "this one replaces it.",
          confirmLabel: "Replace",
        );
  }

  /// Re-read the library of the project a change landed in. The global page
  /// writes the default project's directory, and every project's library
  /// reads a rung of that one, so it reloads every project's; a project's
  /// own pages have one target and reload that one alone.
  Future<void> _reload(String? target) => target == null
      ? reloadAllPromptLibraries(ref)
      : ref.read(promptLibraryProvider(target).notifier).reload();

  /// The picture rows re-read after a write, a rename or a remove — also the
  /// old name's on a rename, its file having moved with the agent. The
  /// whole-family rule for a global write is the shared helper's.
  void _invalidatePicture(String name) =>
      invalidateAgentPicture(ref, name, project: widget.project);

  Future<void> _export(PromptDocument agent) => _guard(() => exportAndSave(
        ref.read(appConfigProvider),
        ref.read(backupHandoffProvider),
        CompletionKind.agent,
        agent.name,
        project: widget.project,
      ));

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  void _say(String message) {
    if (mounted) say(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final agents =
        ref.watch(promptLibraryOf((device: widget.device, project: widget.project)))
            .entries(CompletionKind.agent);
    final userAgents = _userAgents;
    final description = !_writable
        ? "System prompts a message can address as @name in this project. "
            "Shown read-only: the entries are this project's, the default "
            "project's, or the app's own."
        : agents.isEmpty
            ? "System prompts a message can address as @name. None are "
                "installed yet."
            : "System prompts a message can address as @name. The bundled "
                "ones ship with the app; the rest are yours.";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              SectionHeader("Agents", description: description),
              for (final agent in agents) _row(agent, userAgents),
              if (agents.isEmpty && userAgents != null && userAgents.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    "Something in the agents directory is not loadable — a .md "
                    "file with no body in it.",
                  ),
                ),
            ],
          ),
        ),
        if (_writable)
          AddButtonRow(
            child: ValueListenableBuilder(
              valueListenable: _busy,
              builder: (context, busy, _) => Row(
                spacing: 12,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text("Add agent"),
                    onPressed: busy ? null : _add,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.upload_file),
                    label: const Text("Import agent"),
                    onPressed: busy ? null : _import,
                  ),
                ],
              ),
            ),
          ),
        BusyBar(_busy),
      ],
    );
  }

  /// The trailing half of a row. The variable part — edit and remove where
  /// the scanned directory holds the agent and the directory is the user's
  /// to write into, the origin badge where it does not, nothing while the
  /// scan is still out — stands first, and Export last: the trailing slot is
  /// right-aligned, so the row's right edge pins Export whether or not the
  /// scan has landed, and nothing flashes sideways when it does.
  Widget _row(PromptDocument agent, Set<String>? userAgents) {
    final inDir = userAgents?.contains(agent.name);
    final owned = inDir == true && _writable;
    return ListTile(
      dense: true,
      leading: _local ? AgentPicture(name: agent.name, project: widget.project) : null,
      title: Text(agent.name),
      subtitle:
          agent.description == null ? null : Text(agent.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: owned ? () => _edit(agent) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          switch (inDir) {
            // The scan is still out: neither button nor badge is drawn.
            null => const SizedBox.shrink(),
            true when _writable => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: "Edit ${agent.name}",
                    onPressed: () => _edit(agent),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: "Remove ${agent.name}",
                    onPressed: () => _delete(agent),
                  ),
                ],
              ),
            false => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(_originLabel(agent.name)),
              ),
            true => const SizedBox.shrink(),
          },
          if (_local)
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: "Export ${agent.name}",
              onPressed: () => _export(agent),
            ),
        ],
      ),
    );
  }

  /// Where an entry the project's directory does not hold came from: a preset
  /// the binary embeds, or a default-project entry this project inherits.
  String _originLabel(String name) =>
      isBundledPromptName(CompletionKind.agent, name, project: widget.project)
          ? "Bundled"
          : "Inherited";
}

/// What the editor page hands back on save: the [agent] as edited, whose
/// source is what the file becomes. [picture] is a freshly picked
/// image, written as the agent's picture; [removePicture] takes it away on
/// save. Exactly one of the two is set — an edit removed it (null bytes, true)
/// or replaced it (bytes, false) — and neither is when the picture was left
/// alone, so a save without an edit to it keeps whatever the agent already
/// had — and a rename moves what it had under the old name.
typedef AgentEdit = ({
  AgentDefinition agent,
  Uint8List? picture,
  bool removePicture,
});

/// Write an agent's system prompt. The name is the file name, so editing it
/// renames the file — the section takes the old one away when the new one is
/// written. A mention already written into a conversation keeps the meaning it
/// was recorded with; a new mention of the old name is what a rename loses,
/// which is why a rename onto a name another agent holds is refused here. The
/// body is `CompletionField`, so `/skills` and `@agents` complete there the
/// way they do in a trigger's prompt; an agent's prompt is dispatched through
/// the same library. The picture rides the same save: picked bytes are written
/// as `<name>.png` beside the `.md`, a remove takes it away, and a save
/// touching neither leaves what is there — a rename moves it, and a rename
/// with a fresh pick or a remove replaces or takes the old one rather than
/// leaving it behind. The tools are switches over the registry's grantable
/// ones, grouped as the tools group themselves.
class AgentEditorPage extends ConsumerStatefulWidget {
  const AgentEditorPage({
    super.key,
    required this.initial,
    required this.isNew,
    this.project,
    this.initialPicture,
  });

  /// The agent as the page opens on it; its keys the page does not edit are
  /// written back as they were.
  final AgentDefinition initial;

  final bool isNew;

  /// The project whose directory the name's existence is asked against and
  /// whose library the body's completions offer. Null is the default project,
  /// the way it is everywhere a project is named.
  final String? project;

  /// The picture the agent already has, read by the section before the page
  /// opens — shown until a pick or a remove changes what save will do.
  final Uint8List? initialPicture;

  @override
  ConsumerState<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends ConsumerState<AgentEditorPage> {
  late final TextEditingController _name = TextEditingController(text: widget.initial.name);
  late final TextEditingController _description =
      TextEditingController(text: widget.initial.description);
  late final TextEditingController _body =
      TextEditingController(text: widget.initial.instructions);
  String? _nameError;

  /// What an agent may be granted, listed whatever this device can run: the
  /// file means the same on every device it reaches.
  static final _grantable = [
    for (final tool in agentTools(const ToolOffer()))
      if (tool.group != null) tool,
  ];

  static final _known = {for (final tool in _grantable) tool.id};

  /// The ids switched on. Ids this build does not know stay in it, so a
  /// save keeps what a newer build's list named.
  late final Set<String> _initialTools = widget.initial.tools ??
      {
        for (final tool in _grantable)
          if (tool.onByDefault) tool.id,
      };
  late final Set<String> _tools = {..._initialTools};

  /// What the picture row shows: what the agent had, what a pick brought in,
  /// or nothing after a remove. Touched with [_picture] null is "removed on
  /// save"; untouched is "leave it alone" altogether — two fields cover the
  /// four states. Seeded in [initState], an initializer cannot read `widget`.
  Uint8List? _picture;
  bool _pictureTouched = false;

  @override
  void initState() {
    super.initState();
    _picture = widget.initialPicture;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _edited =>
      _name.text != widget.initial.name ||
      _description.text != widget.initial.description ||
      _body.text != widget.initial.instructions ||
      !setEquals(_tools, _initialTools) ||
      _pictureTouched;

  Future<void> _discard() async {
    if (_edited) {
      final ok = await confirm(
        context,
        title: "Discard changes",
        message: "Throw away the edits to this agent?",
        confirmLabel: "Discard",
        destructive: true,
      );
      if (!ok) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// What a pick or a remove records: the touched flag is the save's answer,
  /// the bytes only what the row shows and what goes back where a pick made.
  void _pick(Uint8List? bytes) => setState(() {
        _picture = bytes;
        _pictureTouched = true;
      });

  /// The picture chooser. The image a pick brings in lives only in this page
  /// until Save: nothing is written by choosing, the way nothing else here is.
  Future<void> _pickPicture() async {
    final attachment = await ref
        .read(attachmentPickerProvider)
        .pick(AttachmentKind.image)
        .then((picks) => picks.isEmpty ? null : picks.single);
    if (attachment == null) return;
    if (!attachment.filename.toLowerCase().endsWith(".png")) {
      if (mounted) say(context, "The picture is saved as a .png — pick a PNG image.");
      return;
    }
    _pick(attachment.bytes);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = "A name is required.");
      return;
    }
    if (!isFolderName(name)) {
      setState(() => _nameError = "That name cannot be a file name.");
      return;
    }
    final renaming = !widget.isNew && name != widget.initial.name;
    if (renaming) {
      final config = ref.read(appConfigProvider);
      final taken = await File(agentFilePath(config, name, project: widget.project))
          .exists();
      if (!mounted) return;
      if (taken) {
        setState(() => _nameError = "An agent with that name already exists.");
        return;
      }
    }
    if (!mounted) return;
    // An agent left at the defaults writes no list, so a default added later
    // reaches it.
    final unchanged =
        widget.initial.tools == null && setEquals(_tools, _initialTools);
    Navigator.of(context).pop(
      (
        agent: widget.initial.edited(
          name: name,
          description: _description.text,
          instructions: _body.text,
          tools: unchanged
              ? null
              : {
                  for (final tool in _grantable)
                    if (_tools.contains(tool.id)) tool.id,
                  ..._tools.difference(_known),
                },
        ),
        // Only what was touched: untouched bytes going back would have the
        // section rewrite the same picture over the new name on a rename —
        // over what moving the old one there already put. Touched and null
        // together is "remove on save", and the pair is never both empty and
        // set.
        picture: _pictureTouched ? _picture : null,
        removePicture: _pictureTouched && _picture == null,
      ),
    );
  }

  /// Two tools of one name are one tool worded two ways (`bash` and its
  /// read-only form): switching one on switches the other off.
  void _setTool(AgentTool tool, bool on) => setState(() {
        if (on) {
          _tools.removeAll([
            for (final other in _grantable)
              if (other.name == tool.name) other.id,
          ]);
        }
        on ? _tools.add(tool.id) : _tools.remove(tool.id);
      });

  /// On is every name in [tools] on in one of its forms, and switching the
  /// group on picks each name's first.
  bool _groupOn(List<AgentTool> tools) => tools.every((tool) => tools
      .any((other) => other.name == tool.name && _tools.contains(other.id)));

  void _setGroup(List<AgentTool> tools, bool on) => setState(() {
        _tools.removeAll(tools.map((tool) => tool.id));
        if (!on) return;
        final names = <String>{};
        for (final tool in tools) {
          if (names.add(tool.name)) _tools.add(tool.id);
        }
      });

  List<Widget> _group(ToolGroup group) {
    final tools = [
      for (final tool in _grantable)
        if (tool.group == group) tool,
    ];
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(group.label),
        value: _groupOn(tools),
        onChanged: (on) => _setGroup(tools, on),
      ),
      for (final tool in tools)
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 16),
          title: Text(tool.id),
          subtitle: Text(tool.description,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          value: _tools.contains(tool.id),
          onChanged: (on) => _setTool(tool, on),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_discard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isNew ? "Add agent" : "Edit ${widget.initial.name}"),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: "Discard",
            onPressed: _discard,
          ),
          actions: [
            TextButton(onPressed: _save, child: const Text("Save")),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              Row(
                children: [
                  // The face of the picker as well as the picture itself: with
                  // nothing set it is the person mark, a tap on the picture
                  // opens the chooser, and a remove appears where there is
                  // something to remove.
                  GestureDetector(
                    onTap: _pickPicture,
                    child: Tooltip(
                      message: "Choose a profile picture",
                      child: AgentPictureImage(bytes: _picture, size: 64),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      // What the circle is now, in the editor's own words —
                      // and what save will do about it, where it does
                      // anything. Untouched says what is there, plainly.
                      !_pictureTouched
                          ? _picture == null
                              ? "No picture. A PNG picked here is shown beside "
                                  "the agent's name in the list and in chat."
                              : "The agent's picture."
                          : _picture == null
                              ? "The picture is removed on save."
                              : "A new picture is set on save.",
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  // There, where there is something to remove — a pick, or a
                  // picture the agent already had — and not after: removing
                  // empties it, and clearing what is already gone is noise.
                  if (_picture != null)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: "Remove the picture",
                      onPressed: () => _pick(null),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                autofocus: widget.isNew,
                decoration: InputDecoration(
                  labelText: "Name",
                  hintText: "What @name will address this agent",
                  errorText: _nameError,
                ),
                onChanged: (_) => setState(() => _nameError = null),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: "Description",
                  hintText: "One line shown in the @agent menu",
                ),
              ),
              const SizedBox(height: 12),
              LabelledField(
                label: "System prompt",
                padding: EdgeInsets.zero,
                child: CompletionField(
                  controller: _body,
                  project: widget.project,
                  minLines: 6,
                  maxLines: 12,
                  autofocus: !widget.isNew,
                  decoration: const InputDecoration(
                    hintText: "The system prompt the agent runs under.",
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text("Tools", style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              mutedParagraph(
                  context,
                  "What this agent can use when it runs as a sub-agent or a "
                  "team member. A tool this device cannot run stays off "
                  "whatever is set here."),
              for (final group in ToolGroup.values) ..._group(group),
            ],
          ),
        ),
      ),
    );
  }
}