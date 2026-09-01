import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/platform/platform.dart" as platform;
import "../../domain/models.dart";
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
class AgentsSection extends ConsumerStatefulWidget {
  const AgentsSection({super.key});

  @override
  ConsumerState<AgentsSection> createState() => _AgentsSectionState();
}

class _AgentsSectionState extends ConsumerState<AgentsSection> {
  final _busy = ValueNotifier(false);

  /// Which agents live in the user's directory. Null while the first scan is
  /// out, the same as skills: the library knows what is loaded, not where each
  /// one came from.
  Set<String>? _userAgents;

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
    final dir = config.fs.directory(config.promptsDir(CompletionKind.agent));
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
    if (!_isValidName(edit.name)) {
      _say("That name cannot be a file name.");
      return;
    }
    final config = ref.read(appConfigProvider);
    final file = config.fs.file(_agentPath(config, edit.name));
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
        config.promptsDir(CompletionKind.agent),
        () async {
          final file = config.fs.file(_agentPath(config, edit.name));
          await file.create(recursive: true);
          await file.writeAsString(_encode(edit.description, edit.body));
        },
      );
      await ref.read(promptLibraryProvider(null).notifier).reload();
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
        config.promptsDir(CompletionKind.agent),
        () async {
          await config.fs.file(_agentPath(config, agent.name)).delete();
        },
      );
      await ref.read(promptLibraryProvider(null).notifier).reload();
      await _scan();
      _say("Removed ${agent.name}.");
    });
  }

  Future<void> _guard(Future<void> Function() work) =>
      whileBusy(context, _busy, work);

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final agents = ref.watch(promptLibraryProvider(null)).entries(CompletionKind.agent);
    final userAgents = _userAgents;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Agents",
          description: agents.isEmpty
              ? "System prompts a message can address as @name. None are "
                  "installed yet."
              : "System prompts a message can address as @name. The bundled "
                  "ones ship with the app; the rest are yours.",
        ),
        for (final agent in agents) _row(agent, userAgents),
        if (agents.isEmpty && userAgents != null && userAgents.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Something in the agents directory is not loadable — a .md file "
              "with no body in it.",
            ),
          ),
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

  /// The trailing half of a row: the user's agents can be edited or removed,
  /// the bundled ones say so, and while the scan is still out neither is drawn
  /// — a button that flashes in is a row lying twice in a second.
  Widget _row(PromptDocument agent, Set<String>? userAgents) => ListTile(
        dense: true,
        title: Text(agent.name),
        subtitle: agent.description == null ? null : Text(agent.description!),
        onTap: switch (userAgents?.contains(agent.name)) {
          null => null,
          true => () => _edit(agent),
          false => null,
        },
        trailing: switch (userAgents?.contains(agent.name)) {
          null => null,
          true => Row(
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
          false => const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Text("Bundled"),
          ),
        },
      );
}

/// Where an agent called [name] lives in the user's agents directory.
String _agentPath(AppConfig config, String name) =>
    config.fs.path.join(config.promptsDir(CompletionKind.agent), "$name.md");

/// One directory segment, nothing more: a name holding a separator would reach
/// outside the agents directory, and a dot-name is invisible to nothing but the
/// eye. The same rule the skill importer holds a skill's folder to.
bool _isValidName(String name) =>
    name.isNotEmpty &&
    !name.startsWith(".") &&
    !name.contains("/") &&
    !name.contains("\\");

/// The `.md` source for an agent: a `description` frontmatter, then the body.
String _encode(String description, String body) {
  final desc = description.trim();
  final head = desc.isEmpty ? "" : "---\ndescription: $desc\n---\n\n";
  return "$head${body.trim()}";
}

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
  final GlobalKey<CompletionFieldState> _field = GlobalKey();
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
    if (!_isValidName(name)) {
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
                  key: _field,
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