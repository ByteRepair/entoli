import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/agent_definition.dart";
import "package:entoli_core/model/agent_face.dart";
import "package:entoli_core/model/bot_avatar/spec.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/project.dart" show promptsDirUserWritable;
import "package:entoli_core/model/prompt_library.dart";
import "package:entoli_core/agent/tools/agent_tool.dart";
import "package:entoli_core/store/prompts/skill_import.dart" show isFolderName;

import "../../app/marketplace/install.dart" show PromptInstall;
import "../../app/prompts/agent_files.dart";
import "../../app/prompts/agent_tools.dart";
import "../../app/prompts/own_prompts.dart";
import "../../app/settings/scope.dart";
import "../../data/prompts/agent_pictures.dart" show readOwnAgentFace;
import "../../providers.dart";
import "../bot_avatar/bot_avatar_editor.dart";
import "../widgets/add_button_row.dart";
import "package:entoli_core/view/widgets/agent_picture.dart";
import "package:entoli_core/view/widgets/anchored_menu.dart";
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/dialogs.dart";
import "package:entoli_core/view/widgets/discard_guard.dart";
import "package:entoli_core/view/widgets/page_bar.dart";
import "../widgets/prompt_field.dart";
import "../widgets/section_header.dart";
import "copy_install_link.dart";

const _agentFiles = XTypeGroup(
  label: "Agent",
  extensions: ["md"],
  mimeTypes: ["text/markdown"],
  uniformTypeIdentifiers: ["net.daringfireball.markdown"],
);

/// The agents a message can address by name, at [at]: the default project's
/// on the app's page, a project's on its own. A bundled or inherited agent
/// is listed and not editable; the project's own are written here. A
/// built-in project's and a paired device's are shown read-only.
///
/// Add, Import and View Bot Avatars are the footer, fixed to the bottom of
/// the page so they do not scroll with the list.
class AgentsSettings extends ConsumerStatefulWidget {
  const AgentsSettings({super.key, this.at});

  /// Null is the app's page, the default project's.
  final ProjectAddress? at;

  @override
  ConsumerState<AgentsSettings> createState() => _AgentsSettingsState();
}

class _AgentsSettingsState extends ConsumerState<AgentsSettings> {
  final _busy = ValueNotifier(false);

  ProjectAddress get _address => widget.at ?? const ProjectAddress(null);

  String? get _project => _address.project;

  bool get _local => _address.device == null;

  bool get _writable => _local && promptsDirUserWritable(_project);

  AgentFiles get _files =>
      AgentFiles(ref.read(appConfigProvider), project: _project);

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  Future<void> _add() async {
    final edit = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          initial: AgentDefinition.blank,
          isNew: true,
          project: _project,
        ),
      ),
    );
    if (edit == null || !mounted) return;
    if (!await _mayReplace(edit.agent.name, "Saving")) return;
    await _write(edit.agent.name, edit.agent.toSource(), face: edit.face);
  }

  Future<void> _edit(PromptDocument agent) async {
    // This project's own face, not the tiers' answer: the editor edits the
    // level it writes, so an inherited face shows on the rows but not here.
    AgentFace? face;
    await _guard(() async {
      face = await readOwnAgentFace(
        ref.read(appConfigProvider),
        agent.name,
        project: _project,
      );
    });
    if (!mounted) return;
    final edit = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          initial: AgentDefinition.of(agent),
          isNew: false,
          project: _project,
          initialFace: face,
        ),
      ),
    );
    if (edit == null || !mounted) return;
    await _write(
      edit.agent.name,
      edit.agent.toSource(),
      removes: agent.name,
      face: edit.face,
    );
  }

  /// The one write the page makes, editor save and import alike. An agent
  /// written over another does not keep the face of the one it replaced.
  Future<void> _write(
    String name,
    String source, {
    String? removes,
    AgentFace? face,
    String verb = "Saved",
  }) => _guard(() async {
    await _files.write(name, source, removes: removes, face: face);
    await ref.read(promptChangesProvider).reload(_project);
    if (mounted) notify(context, "$verb $name.");
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
    if (!confirmed || !mounted) return;
    await _guard(() async {
      await _files.delete(agent.name);
      await ref.read(promptChangesProvider).reload(_project);
      if (mounted) notify(context, "Removed ${agent.name}.");
    });
  }

  /// An imported `.md` lands under its file's own name.
  Future<void> _import() async {
    ({String name, String source})? read;
    await _guard(() async {
      final file = await openFile(acceptedTypeGroups: const [_agentFiles]);
      if (file == null) return;
      read = AgentFiles.import(
        file.name,
        await file.readAsBytes(),
        refuse: (why) {
          if (mounted) say(context, why);
        },
      );
    });
    final agent = read;
    if (agent == null || !mounted) return;
    if (!await _mayReplace(agent.name, "Importing")) return;
    await _write(agent.name, agent.source, verb: "Imported");
  }

  /// False where [name] is already in this project's directory and the user
  /// would rather keep it.
  Future<bool> _mayReplace(String name, String doing) async {
    final replacing = PromptInstall(
      ref.read,
      target: _project,
    ).replacingAgent(name, doing: doing);
    return replacing == null ||
        await confirm(
          context,
          title: replacing.title,
          message: replacing.message,
          confirmLabel: "Replace",
        );
  }

  @override
  Widget build(BuildContext context) {
    final agents = ref
        .watch(promptLibraryOf(_address.ref))
        .entries(CompletionKind.agent);
    // Null while the scan is out: neither the actions nor the badge of an
    // entry is known until it lands.
    final own = _local ? ref.watch(ownAgentsProvider(_project)).value : null;
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
              for (final agent in agents) _row(agent, own),
              if (agents.isEmpty && own != null && own.isNotEmpty)
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
        // The avatar library is this device's, so a paired device's list
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

  /// The variable part of the trailing slot stands first and Export last:
  /// the slot is right-aligned, so nothing flashes sideways when the scan
  /// lands.
  Widget _row(PromptDocument agent, Set<String>? own) {
    final inDir = own?.contains(agent.name);
    final owned = inDir == true && _writable;
    return ListTile(
      dense: true,
      // Live, and happy at a tap: a row scrolled out of view is not
      // painted, which stops its ticker until it is back.
      leading: _local
          ? AgentPicture(
              name: agent.name,
              project: _project,
              animate: true,
              reactToTap: true,
            )
          : null,
      title: Text(agent.name),
      subtitle: switch (agent.description) {
        final words? when words.isNotEmpty => Text(
          words,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        _ => null,
      },
      onTap: owned ? () => _edit(agent) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (owned) ...[
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
          ] else if (inDir == false)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                promptOrigin(CompletionKind.agent, agent.name, _project),
              ),
            ),
          if (_local)
            PromptRowActions(
              kind: CompletionKind.agent,
              name: agent.name,
              project: _project,
              guard: _guard,
            ),
        ],
      ),
    );
  }
}

/// What the editor hands back on save: the [agent] as edited and the [face]
/// it now has, null for none. The editor opens on the agent's own face, so
/// an untouched one goes back as it was.
typedef AgentEdit = ({AgentDefinition agent, AgentFace? face});

/// An agent's name, which is its file's, what it is for, its system prompt,
/// its face and the tools it is granted, saved together. A rename onto a
/// name another agent holds is refused here; an add onto one is the list's
/// to confirm.
class AgentEditorPage extends ConsumerStatefulWidget {
  const AgentEditorPage({
    super.key,
    required this.initial,
    required this.isNew,
    this.project,
    this.initialFace,
  });

  /// Its keys the page does not edit are written back as they were.
  final AgentDefinition initial;

  final bool isNew;

  /// Whose directory a rename is checked against and whose library the
  /// system prompt completes from. Null is the default project.
  final String? project;

  final AgentFace? initialFace;

  @override
  ConsumerState<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends ConsumerState<AgentEditorPage> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _description = TextEditingController(
    text: widget.initial.description,
  );
  late String _body = widget.initial.instructions;
  late final _tools = AgentToolPicks(widget.initial);
  String? _nameError;

  /// What the face row shows. Touched with [_face] null is "removed on
  /// save"; untouched is "leave it alone".
  late AgentFace? _face = widget.initialFace;
  bool _faceTouched = false;

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
      _tools.changed ||
      _faceTouched;

  void _pick(AgentFace? face) => setState(() {
    _face = face;
    _faceTouched = true;
  });

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

  Future<void> _pickPicture() => guarded(context, () async {
    final picks = await ref
        .read(attachmentPickerProvider)
        .pick(AttachmentKind.image);
    if (picks.isEmpty || !mounted) return;
    final attachment = picks.single;
    if (!attachment.filename.toLowerCase().endsWith(".png")) {
      say(context, "The picture is saved as a .png — pick a PNG image.");
      return;
    }
    _pick(AgentPhoto(attachment.bytes));
  });

  String? _problem(String name) {
    if (name.isEmpty) return "A name is required.";
    if (!isFolderName(name)) return "That name cannot be a file name.";
    final renaming = !widget.isNew && name != widget.initial.name;
    final files = AgentFiles(
      ref.read(appConfigProvider),
      project: widget.project,
    );
    if (renaming && files.has(name)) {
      return "An agent with that name already exists.";
    }
    return null;
  }

  void _save() {
    final name = _name.text.trim();
    final problem = _problem(name);
    if (problem != null) {
      setState(() => _nameError = problem);
      return;
    }
    // A .md with no body is not loadable.
    if (_body.trim().isEmpty) {
      say(context, "Write the system prompt first.");
      return;
    }
    Navigator.of(context).pop((
      agent: widget.initial.edited(
        name: name,
        description: _description.text,
        instructions: _body,
        tools: _tools.written,
      ),
      face: _face,
    ));
  }

  List<Widget> _group(ToolGroup group) {
    final tools = [
      for (final tool in grantableAgentTools)
        if (tool.group == group) tool,
    ];
    if (tools.isEmpty) return const [];
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(group.label),
        value: _tools.groupOn(group),
        onChanged: (on) => setState(() => _tools.setGroup(group, on)),
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
          value: _tools.isOn(tool),
          onChanged: (on) => setState(() => _tools.set(tool, on)),
        ),
    ];
  }

  /// The face, which is also the button that changes it.
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
  Widget build(BuildContext context) => DiscardGuard(
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
            // Wraps and grows down rather than scrolling sideways, so the
            // whole of it is read before it is saved; Enter is still done.
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
