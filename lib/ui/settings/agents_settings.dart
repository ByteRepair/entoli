import "dart:async";
import "dart:convert";

import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/prompt_export.dart";
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

const _agentFiles = XTypeGroup(
  label: "Agent",
  extensions: ["md"],
  mimeTypes: ["text/markdown"],
  uniformTypeIdentifiers: ["net.daringfireball.markdown"],
  webWildCards: ["text/markdown", "text/plain"],
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
      MaterialPageRoute(builder: (_) => AgentEditorPage(isNew: true, project: widget.project)),
    );
    if (result == null || !mounted) return;
    await _save(result, previous: null);
  }

  Future<void> _edit(PromptDocument agent) async {
    final result = await Navigator.of(context).push<AgentEdit>(
      MaterialPageRoute(
        builder: (_) => AgentEditorPage(
          isNew: false,
          project: widget.project,
          initialName: agent.name,
          initialDescription: agent.description ?? "",
          initialBody: agent.body,
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
    if (!isFolderName(edit.name)) {
      _say("That name cannot be a file name.");
      return;
    }
    final config = ref.read(appConfigProvider);
    if (previous == null) {
      final exists = await config.fs
          .file(agentFilePath(config, edit.name, project: widget.project))
          .exists();
      if (!mounted) return;
      if (exists) {
        final confirmed = await confirm(
          context,
          title: "Replace ${edit.name}?",
          message: "An agent with that name is already installed. Saving this one "
              "replaces it.",
          confirmLabel: "Replace",
        );
        if (!confirmed) return;
      }
    }

    await _write(
      edit.name,
      PromptDocument.toSource(description: edit.description, body: edit.body),
      "Saved ${edit.name}.",
      removes: previous,
    );
  }

  /// The one write an agent page makes — editor save or import alike — with
  /// the library reload and directory rescan that land it on the list.
  /// [removes] names the file a rename takes away, written over first so a
  /// failure halfway leaves the agent where it was. The create is
  /// load-bearing: `writeAsString` does not make parents.
  Future<void> _write(String name, String source, String said,
          {String? removes}) =>
      _guard(() async {
        final config = ref.read(appConfigProvider);
        await platform.withWritableDir(
          config.promptsDir(CompletionKind.agent, project: widget.project),
          () async {
            final file =
                config.fs.file(agentFilePath(config, name, project: widget.project));
            await file.create(recursive: true);
            await file.writeAsString(source);
            if (removes != null && removes != name) {
              await config.fs
                  .file(agentFilePath(config, removes, project: widget.project))
                  .delete();
            }
          },
        );
        await _reload();
        await _scan();
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
      await platform.withWritableDir(
        config.promptsDir(CompletionKind.agent, project: widget.project),
        () async {
          await config.fs
              .file(agentFilePath(config, agent.name, project: widget.project))
              .delete();
        },
      );
      await _reload();
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

    final source = utf8.decode(bytes, allowMalformed: true);
    final document = PromptDocument.parse(CompletionKind.agent, "", source);
    if (document.body.isEmpty) {
      _say("That file cannot be imported: there is no prompt in it.");
      return;
    }
    final config = ref.read(appConfigProvider);
    final name = config.fs.path.basenameWithoutExtension(file.name);
    if (!isFolderName(name)) {
      _say("That file cannot be imported: its name cannot be a file name.");
      return;
    }
    final exists = await config.fs
        .file(agentFilePath(config, name, project: widget.project))
        .exists();
    if (!mounted) return;
    if (exists) {
      final confirmed = await confirm(
        context,
        title: "Replace $name?",
        message: "An agent with that name is already installed. Importing "
            "this one replaces it.",
        confirmLabel: "Replace",
      );
      if (!confirmed) return;
    }

    await _write(name, source, "Imported $name.");
  }

  /// An agent page has one directory it writes into, so one project's
  /// library is all a change here has to rebuild.
  Future<void> _reload() => ref
      .read(promptLibraryProvider(widget.project).notifier)
      .reload();

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
                child: Text(_originLabel(CompletionKind.agent, agent.name)),
              ),
            true => const SizedBox.shrink(),
          },
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
  String _originLabel(CompletionKind kind, String name) =>
      isBundledPromptName(kind, name, project: widget.project)
          ? "Bundled"
          : "Inherited";
}

/// What the editor page hands back on save.
typedef AgentEdit = ({String name, String description, String body});

/// Write an agent's system prompt. The name is the file name, so editing it
/// renames the file — the section takes the old one away when the new one is
/// written. A mention already written into a conversation keeps the meaning it
/// was recorded with; a new mention of the old name is what a rename loses,
/// which is why a rename onto a name another agent holds is refused here. The
/// body is `CompletionField`, so `/skills` and `@agents` complete there the
/// way they do in a trigger's prompt; an agent's prompt is dispatched through
/// the same library.
class AgentEditorPage extends ConsumerStatefulWidget {
  const AgentEditorPage({
    super.key,
    required this.isNew,
    this.project,
    this.initialName = "",
    this.initialDescription = "",
    this.initialBody = "",
  });

  final bool isNew;

  /// The project whose directory the name's existence is asked against and
  /// whose library the body's completions offer. Null is the default project,
  /// the way it is everywhere a project is named.
  final String? project;
  final String initialName;
  final String initialDescription;
  final String initialBody;

  @override
  ConsumerState<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends ConsumerState<AgentEditorPage> {
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
    final renaming = !widget.isNew && name != widget.initialName;
    if (renaming) {
      final config = ref.read(appConfigProvider);
      final taken = await config.fs
          .file(agentFilePath(config, name, project: widget.project))
          .exists();
      if (!mounted) return;
      if (taken) {
        setState(() => _nameError = "An agent with that name already exists.");
        return;
      }
    }
    if (!mounted) return;
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
            ],
          ),
        ),
      ),
    );
  }
}