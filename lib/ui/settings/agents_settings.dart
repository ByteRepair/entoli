import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:flutter/foundation.dart" show setEquals;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/prompts/agent_files.dart";
import "../../data/builtin/tools/agent_tool.dart";
import "../../data/builtin/tools/registry.dart";
import "../../data/prompts/agent_pictures.dart";
import "../../data/prompts/prompt_export.dart";
import "../../data/prompts/skill_import.dart";
import "../../domain/agent_definition.dart";
import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show promptsDirUserWritable;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../bot_avatar/bot_avatar_editor.dart";
import "../widgets/add_button_row.dart";
import "../widgets/agent_picture.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/busy.dart";
import "copy_install_link.dart";
import "../widgets/dialogs.dart";
import "../widgets/discard_guard.dart";
import "../widgets/prompt_field.dart";
import "../widgets/section_header.dart";
import "../widgets/page_bar.dart";

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

  AgentFiles get _files =>
      AgentFiles(ref.read(appConfigProvider), project: widget.project);

  Future<void> _scan() async {
    final names = await _files.own();
    if (mounted) setState(() => _userAgents = names);
  }

  Future<void> _add() async {
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          initial: AgentDefinition.blank,
          isNew: true,
          project: widget.project,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _save(result, previous: null);
  }

  Future<void> _edit(PromptDocument agent) async {
    final config = ref.read(appConfigProvider);
    // This project's own face, not the tiers' answer: the editor edits the
    // level it writes. A face inherited from the default project's directory
    // shows on the rows but not here — choosing one sets this project's, and
    // a remove takes this project's away, where "removed on save" would
    // otherwise leave the inherited one on screen.
    final face = await readOwnAgentFace(
      config,
      agent.name,
      project: widget.project,
    );
    if (!mounted) return;
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          initial: AgentDefinition.of(agent),
          isNew: false,
          project: widget.project,
          initialFace: face,
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
      face: edit.face,
    );
  }

  /// The one write an agent page makes — editor save or import alike — with
  /// the library reload and directory rescan that land it on the list.
  /// [removes] names the file a rename takes away, written over first so a
  /// failure halfway leaves the agent where it was. [face] is what the agent
  /// looks like now, null for none: an agent written over another — an
  /// import, a replace — does not keep the face of the one it replaced, and
  /// a rename takes the old name's face away. The create is load-bearing:
  /// `writeAsString` does not make parents.
  Future<void> _write(
    String name,
    String source,
    String said, {
    String? removes,
    AgentFace? face,
  }) => _guard(() async {
    await _files.write(name, source, removes: removes, face: face);
    await _reload(widget.project);
    await _scan();
    _say(said);
  });

  Future<void> _delete(PromptDocument agent) async {
    final confirmed = await confirm(
      context,
      title: "Remove ${agent.name}?",
      message:
          "The agent is deleted. A bundled agent of the same name, if "
          "there is one, is back the next time the library loads.",
      confirmLabel: "Remove",
      destructive: true,
    );
    if (!confirmed) return;

    await _guard(() async {
      await _files.delete(agent.name);
      await _reload(widget.project);
      await _scan();
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

    final read = AgentFiles.import(file.name, bytes, refuse: _say);
    if (read == null) return;
    final (:name, :source) = read;
    if (!await _mayReplace(name, "Importing")) return;
    await _write(name, source, "Imported $name.");
  }

  /// False where [name] is already in this project's directory and the user
  /// would rather keep it, or the page went away while asking.
  Future<bool> _mayReplace(String name, String doing) async {
    final exists = _files.has(name);
    if (!mounted) return false;
    return !exists ||
        await confirm(
          context,
          title: "Replace $name?",
          message:
              "An agent with that name is already installed. $doing "
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

  Future<void> _export(PromptDocument agent) => _guard(
    () => exportAndSave(
      ref.read(appConfigProvider),
      ref.read(backupHandoffProvider),
      CompletionKind.agent,
      agent.name,
      project: widget.project,
    ),
  );

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  void _say(String message) {
    if (mounted) say(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final agents = ref
        .watch(
          promptLibraryOf((device: widget.device, project: widget.project)),
        )
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
        // The avatar library is this device's, so a remote device's list
        // has no way to it.
        if (_local)
          AddButtonRow(
            child: ValueListenableBuilder(
              valueListenable: _busy,
              builder: (context, busy, _) => Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (_writable) ...[
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
                  OutlinedButton.icon(
                    icon: const Icon(Icons.smart_toy_outlined),
                    label: const Text("View Bot Avatars"),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BotAvatarEditorPage.browse(),
                      ),
                    ),
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
      leading: _local
          // Live, and happy at a tap: a row scrolled out of view is not
          // painted, which stops its ticker until it is back.
          ? AgentPicture(
              name: agent.name,
              project: widget.project,
              animate: true,
              reactToTap: true,
            )
          : null,
      title: Text(agent.name),
      subtitle: agent.description == null
          ? null
          : Text(
              agent.description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
              icon: const Icon(Icons.link),
              tooltip: "Copy install link for ${agent.name}",
              onPressed: () => _guard(
                () => copyInstallLink(
                  context,
                  ref.read(appConfigProvider),
                  CompletionKind.agent,
                  agent.name,
                  project: widget.project,
                ),
              ),
            ),
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
/// source is what the file becomes, and the [face] it now has — a photo, a
/// Bot Avatar, or none. The editor opened on the agent's own face, so an
/// untouched one goes back as it was.
typedef AgentEdit = ({AgentDefinition agent, AgentFace? face});

/// Write an agent's system prompt. The name is the file name, so editing it
/// renames the file — the section takes the old one away when the new one is
/// written. A mention already written into a conversation keeps the meaning it
/// was recorded with; a new mention of the old name is what a rename loses,
/// which is why a rename onto a name another agent holds is refused here. The
/// body is a `PromptField`, the trigger's prompt's: shown as it is set, and
/// written on a page of its own where `/skills` and `@agents` complete; an
/// agent's prompt is dispatched through the same library. The face rides the
/// same save: a tap on it offers a photo upload or a Bot Avatar (the
/// avatar editor), and a remove where there is one. Whichever is chosen is
/// written beside the `.md` — `<name>.png` or `<name>.avatar.json` — the
/// other taken away; a save touching neither leaves what is there, a rename
/// moves it, and a rename with a fresh choice or a remove replaces or takes
/// the old one rather than leaving it behind. The tools are switches over the registry's grantable
/// ones, grouped as the tools group themselves.
class AgentEditorPage extends ConsumerStatefulWidget {
  const AgentEditorPage({
    super.key,
    required this.initial,
    required this.isNew,
    this.project,
    this.initialFace,
  });

  /// The agent as the page opens on it; its keys the page does not edit are
  /// written back as they were.
  final AgentDefinition initial;

  final bool isNew;

  /// The project whose directory the name's existence is asked against and
  /// whose library the body's completions offer. Null is the default project,
  /// the way it is everywhere a project is named.
  final String? project;

  /// The face the agent already has, read by the section before the page
  /// opens — shown until a choice or a remove changes what save will do.
  final AgentFace? initialFace;

  @override
  ConsumerState<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends ConsumerState<AgentEditorPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial.name,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.initial.description,
  );
  late String _body = widget.initial.instructions;
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
  late final Set<String> _initialTools =
      widget.initial.tools ??
      {
        for (final tool in _grantable)
          if (tool.onByDefault) tool.id,
      };
  late final Set<String> _tools = {..._initialTools};

  /// What the face row shows: what the agent had, what a choice brought in,
  /// or nothing after a remove. Touched with [_face] null is "removed on
  /// save"; untouched is "leave it alone" altogether — two fields cover the
  /// states. Seeded in [initState], an initializer cannot read `widget`.
  AgentFace? _face;
  bool _faceTouched = false;

  @override
  void initState() {
    super.initState();
    _face = widget.initialFace;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _edited =>
      _name.text != widget.initial.name ||
      _description.text != widget.initial.description ||
      _body != widget.initial.instructions ||
      !setEquals(_tools, _initialTools) ||
      _faceTouched;

  /// What a choice or a remove records: the touched flag is the save's
  /// answer, the face only what the row shows and what goes back.
  void _pick(AgentFace? face) => setState(() {
    _face = face;
    _faceTouched = true;
  });

  /// The avatar editor, on the Bot Avatar the agent wears where it wears one.
  /// What it hands back lives only in this page until Save.
  Future<void> _chooseBot() async {
    final spec = await Navigator.of(context).push<BotAvatarSpec>(
      MaterialPageRoute(
        builder: (_) => BotAvatarEditorPage(
          initial: switch (_face) {
            AgentBot(:final spec) => spec,
            _ => null,
          },
        ),
      ),
    );
    if (spec != null && mounted) _pick(AgentBot(spec));
  }

  /// The picture chooser. The image a pick brings in lives only in this page
  /// until Save: nothing is written by choosing, the way nothing else here is.
  Future<void> _pickPicture() async {
    final attachment = await ref
        .read(attachmentPickerProvider)
        .pick(AttachmentKind.image)
        .then((picks) => picks.isEmpty ? null : picks.single);
    if (attachment == null) return;
    if (!attachment.filename.toLowerCase().endsWith(".png")) {
      if (mounted) {
        say(context, "The picture is saved as a .png — pick a PNG image.");
      }
      return;
    }
    _pick(AgentPhoto(attachment.bytes));
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
      final taken = File(
        agentFilePath(config, name, project: widget.project),
      ).existsSync();
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
    Navigator.of(context).pop((
      agent: widget.initial.edited(
        name: name,
        description: _description.text,
        instructions: _body,
        tools: unchanged
            ? null
            : {
                for (final tool in _grantable)
                  if (_tools.contains(tool.id)) tool.id,
                ..._tools.difference(_known),
              },
      ),
      face: _face,
    ));
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
  bool _groupOn(List<AgentTool> tools) => tools.every(
    (tool) => tools.any(
      (other) => other.name == tool.name && _tools.contains(other.id),
    ),
  );

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
          subtitle: Text(
            tool.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          value: _tools.contains(tool.id),
          onChanged: (on) => _setTool(tool, on),
        ),
    ];
  }

  /// The face, which is also the button that changes it: a tap opens a menu
  /// of an uploaded photo or a Bot Avatar, and a remove where there is
  /// something to remove.
  Widget _faceRow() {
    final face = _face;
    return Row(
      children: [
        Builder(
          builder: (button) => Tooltip(
            message: "Change the profile picture",
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () async {
                PopupMenuItem<VoidCallback> item(
                  IconData icon,
                  String label,
                  VoidCallback action,
                ) => PopupMenuItem(
                  value: action,
                  child: ListTile(leading: Icon(icon), title: Text(label)),
                );
                final action = await showAnchoredMenu(button, [
                  item(Icons.upload_outlined, "Upload photo", _pickPicture),
                  item(
                    Icons.smart_toy_outlined,
                    face is AgentBot ? "Edit Bot Avatar" : "Use Bot Avatar",
                    _chooseBot,
                  ),
                  if (face != null)
                    item(Icons.close, "Remove", () => _pick(null)),
                ]);
                if (button.mounted) action?.call();
              },
              child: AgentPictureImage(face: face, size: 64, animate: true),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            // What the face is now, in the editor's own words — and what
            // save will do about it, where it does anything.
            !_faceTouched
                ? switch (face) {
                    null =>
                      "No picture. Tap the circle to upload a photo or "
                          "choose a Bot Avatar, shown beside the agent's "
                          "name in the list and in chat.",
                    AgentPhoto() => "The agent's picture.",
                    AgentBot(:final spec) =>
                      "The agent's Bot Avatar, ${spec.definition.name}.",
                  }
                : switch (face) {
                    null => "The picture is removed on save.",
                    AgentPhoto() => "A new picture is set on save.",
                    AgentBot(:final spec) =>
                      "${spec.definition.name} is set as the Bot Avatar "
                          "on save.",
                  },
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DiscardGuard(
      edited: () => _edited,
      message: "Throw away the edits to this agent?",
      child: Scaffold(
        appBar: PageBar(
          title: widget.isNew ? "Add agent" : "Edit ${widget.initial.name}",
          leading: PageLeading.close,
          actions: [PageAction.text(label: "Save", onPressed: _save)],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              _faceRow(),
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
              // Wraps and grows down rather than scrolling sideways: a
              // description is often a sentence or two, and the whole of it
              // should be read before it is saved. Still one line of the
              // menu's, so Enter is done rather than a line break.
              TextField(
                controller: _description,
                minLines: 1,
                maxLines: null,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: "Description",
                  hintText: "Shown in the @agent menu",
                ),
              ),
              const SizedBox(height: 12),
              PromptField(
                label: "System prompt",
                value: _body,
                hint: "The system prompt the agent runs under.",
                project: widget.project,
                padding: EdgeInsets.zero,
                onChanged: (body) => setState(() => _body = body),
              ),
              const SizedBox(height: 16),
              Text("Tools", style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              mutedParagraph(
                context,
                "What this agent can use when it runs as a sub-agent or a "
                "team member. A tool this device cannot run stays off "
                "whatever is set here.",
              ),
              for (final group in ToolGroup.values) ..._group(group),
            ],
          ),
        ),
      ),
    );
  }
}
