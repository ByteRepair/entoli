import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/skill_import.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show promptsDirUserWritable;
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/busy.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The agents a message can address by name. The list is the library's; the
/// page's own question is where each one came from — a bundled agent is
/// Entoli's and not editable, the user's are written here and are. An agent is
/// one flat `.md` file (a system prompt with `description` frontmatter), so it
/// is written in-app rather than imported the way a skill's directory is.
///
/// [project] is whose set the page reads and whose directory it writes: null
/// is the app-level page and the default project, a name is that project's
/// settings page. A built-in project's page is view-only — it shows the
/// entries its directory, the default's and the bundled presets make up, with
/// nothing to change any of them, since a turn in it answers to the spec.
class AgentsSection extends ConsumerStatefulWidget {
  const AgentsSection({super.key, this.project});

  final String? project;

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

  bool get _writable => promptsDirUserWritable(widget.project);

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final config = ref.read(appConfigProvider);
    final names = <String>{};
    final dir = config.fs
        .directory(config.promptsDir(CompletionKind.agent, project: widget.project));
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && config.fs.path.extension(entity.path) == ".md") {
          names.add(config.fs.path.basenameWithoutExtension(entity.path));
        }
      }
    }
    if (mounted) setState(() => _userAgents = names);
  }

  Future<void> _add() async {
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(builder: (_) => const AgentEditorPage(isNew: true)),
    );
    if (result == null || !mounted) return;
    await _save(result, replacing: false);
  }

  Future<void> _edit(PromptDocument agent) async {
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          isNew: false,
          initialName: agent.name,
          initialDescription: agent.description ?? "",
          initialBody: agent.body,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _save(result, replacing: true);
  }

  Future<void> _save(AgentEdit edit, {required bool replacing}) async {
    if (!isFolderName(edit.name)) {
      _say("That name cannot be a file name.");
      return;
    }
    final config = ref.read(appConfigProvider);
    final file = config.fs.file(_agentPath(config, edit.name, project: widget.project));
    final exists = await file.exists();
    if (!mounted) return;
    if (!replacing && exists) {
      final confirmed = await confirm(
        context,
        title: "Replace ${edit.name}?",
        message: "An agent with that name is already installed. Saving this one "
            "replaces it.",
        confirmLabel: "Replace",
      );
      if (!confirmed) return;
    }

    await _guard(() async {
      final config = ref.read(appConfigProvider);
      await platform.withWritableDir(
        config.promptsDir(CompletionKind.agent, project: widget.project),
        () async {
          final file =
              config.fs.file(_agentPath(config, edit.name, project: widget.project));
          await file.create(recursive: true);
          await file.writeAsString(
              PromptDocument.toSource(description: edit.description, body: edit.body));
        },
      );
      await _reload();
      await _scan();
      _say(replacing ? "Saved ${edit.name}." : "Added ${edit.name}.");
    });
  }

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
      await platform.withWritableDir(
        config.promptsDir(CompletionKind.agent, project: widget.project),
        () async {
          await config.fs
              .file(_agentPath(config, agent.name, project: widget.project))
              .delete();
        },
      );
      await _reload();
      await _scan();
      _say("Removed ${agent.name}.");
    });
  }

  /// An agent page has one directory it writes into, so one project's
  /// library is all a change here has to rebuild.
  Future<void> _reload() => ref
      .read(promptLibraryProvider(widget.project).notifier)
      .reload();

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final agents =
        ref.watch(promptLibraryProvider(widget.project)).entries(CompletionKind.agent);
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
        SectionHeader("Agents", description: description),
        for (final agent in agents) _row(agent, userAgents),
        if (agents.isEmpty && userAgents != null && userAgents.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Something in the agents directory is not loadable — a .md file "
              "with no body in it.",
            ),
          ),
        if (_writable)
          AddButtonRow(
            child: ValueListenableBuilder(
              valueListenable: _busy,
              builder: (context, busy, _) => OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text("Add agent"),
                onPressed: busy ? null : _add,
              ),
            ),
          ),
        BusyBar(_busy),
      ],
    );
  }

  /// The trailing half of a row: an agent the scanned directory holds is this
  /// project's own and can be edited or removed, an inherited or bundled one
  /// is not here and says which, and while the scan is still out neither is
  /// drawn — a button that flashes in is a row lying twice in a second.
  Widget _row(PromptDocument agent, Set<String>? userAgents) {
    final inDir = userAgents?.contains(agent.name);
    final owned = inDir == true && _writable;
    return ListTile(
      dense: true,
      title: Text(agent.name),
      subtitle: agent.description == null ? null : Text(agent.description!),
      onTap: owned ? () => _edit(agent) : null,
      trailing: switch (inDir) {
        null => null,
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
            child: Text(_originLabel(CompletionKind.agent, agent.name)),
          ),
        true => null,
      },
    );
  }

  /// Where an entry the project's directory does not hold came from: a preset
  /// the binary embeds, or a default-project entry this project inherits.
  String _originLabel(CompletionKind kind, String name) =>
      isBundledPromptName(kind, name, project: widget.project)
          ? "Bundled"
          : "Inherited";
}

/// Where an agent called [name] lives: [project]'s own agents directory — the
/// default project's where it is null.
String _agentPath(AppConfig config, String name, {String? project}) =>
    config.fs.path
        .join(config.promptsDir(CompletionKind.agent, project: project), "$name.md");

/// What the editor page hands back on save.
typedef AgentEdit = ({String name, String description, String body});

/// Write an agent's system prompt. The name is fixed once the agent exists —
/// it is the file name, and renaming it would orphan every `@name` mention
/// already written into a conversation. The body is `CompletionField`, so
/// `/skills` and `@agents` complete there the way they do in a reminder's
/// prompt; an agent's prompt is dispatched through the same library.
class AgentEditorPage extends StatefulWidget {
  const AgentEditorPage({
    super.key,
    required this.isNew,
    this.initialName = "",
    this.initialDescription = "",
    this.initialBody = "",
  });

  final bool isNew;
  final String initialName;
  final String initialDescription;
  final String initialBody;

  @override
  State<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends State<AgentEditorPage> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName);
  late final TextEditingController _description =
      TextEditingController(text: widget.initialDescription);
  late final TextEditingController _body = TextEditingController(text: widget.initialBody);
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _edited =>
      _name.text != widget.initialName ||
      _description.text != widget.initialDescription ||
      _body.text != widget.initialBody;

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

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = "A name is required.");
      return;
    }
    if (!isFolderName(name)) {
      setState(() => _nameError = "That name cannot be a file name.");
      return;
    }
    Navigator.of(context).pop(
      (name: name, description: _description.text, body: _body.text),
    );
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
          title: Text(widget.isNew ? "Add agent" : "Edit ${widget.initialName}"),
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
              TextField(
                controller: _name,
                autofocus: widget.isNew,
                enabled: widget.isNew,
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
                child: CompletionField(
                  controller: _body,
                  minLines: 6,
                  maxLines: 12,
                  autofocus: !widget.isNew,
                  decoration: const InputDecoration(
                    hintText: "The system prompt the agent runs under.",
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}