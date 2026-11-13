import "package:file_selector/file_selector.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/builtin/tools/agent_tool.dart";
import "../../../data/builtin/tools/registry.dart";
import "../../../data/prompts/agent_pictures.dart" show readOwnAgentFace;
import "../../../data/prompts/prompt_export.dart";
import "../../../data/prompts/skill_import.dart";
import "../../../domain/agent_definition.dart";
import "../../../domain/agent_face.dart";
import "../../../domain/models.dart";
import "../../../domain/app_link.dart" show appLinkMaxLength;
import "../../../domain/project.dart" show projectLabel, promptsDirUserWritable;
import "../../../domain/prompt_library.dart";
import "../../../providers.dart";
import "../../prompts/agent_files.dart";
import "../../prompts/skill_files.dart";
import "../controller.dart";
import "../hand_off.dart";
import "../scope.dart";
import "../spec.dart";

/// A project's own agents and skills, by name: which entries of its library
/// its directory holds, the rest inherited or bundled; and for a skill, what
/// its folder is wrong about. Asked again after every write, and each time a
/// page shows them, so a file put there behind the app's back is found.
final ownAgentsProvider = FutureProvider.autoDispose
    .family<Set<String>, String?>(
      (ref, project) =>
          AgentFiles(ref.watch(appConfigProvider), project: project).own(),
    );

final ownSkillsProvider = FutureProvider.autoDispose
    .family<Map<String, List<String>>, String?>(
      (ref, project) =>
          SkillFiles(ref.watch(appConfigProvider), project: project).own(),
    );

/// Which project's agents and skills a page is about, and whether they are
/// this device's: a paired device's are shown, its files being there.
({String? project, String? device}) _whose(SettingContext c) =>
    switch (c.scope) {
      ProjectScope(:final project, :final device) => (
        project: project,
        device: device,
      ),
      _ => (project: null, device: null),
    };

/// Where an imported skill goes: null is the default project, the base set
/// every project inherits.
final skillDestinationProvider = NotifierProvider<SkillDestination, String?>(
  SkillDestination.new,
);

class SkillDestination extends Notifier<String?> {
  @override
  String? build() => null;

  void pick(String? project) => state = project;
}

/// Re-read the library a change to [project]'s directory landed in, and
/// what lists the project's own. The default project's is a rung of every
/// project's library, so a change there reloads every one.
Future<void> _reload(SettingReader ref, String? project) async {
  if (project == null) {
    await reloadAllPromptLibraries(ref.read);
  } else {
    await ref.read(promptLibraryProvider(project).notifier).reload();
  }
  ref.invalidate(ownAgentsProvider(project));
  ref.invalidate(ownSkillsProvider(project));
}

/// [name]'s install link, copied, or why it cannot be one.
Future<SettingNotice> _link(
  SettingReader ref,
  CompletionKind kind,
  String name,
  String? project,
) async {
  final link = await installLinkOf(
    ref.read(appConfigProvider),
    kind,
    name,
    project: project,
  );
  if (link.length > appLinkMaxLength) {
    return SettingNotice(
      "$name is too big for a link. Export it as a file instead.",
    );
  }
  return SettingNotice("Copied an install link for $name.", copy: link);
}

/// Where an entry a project's directory does not hold came from: a preset
/// the binary embeds, or a default-project entry this project inherits.
String _origin(CompletionKind kind, String name, String? project) =>
    isBundledPromptName(kind, name, project: project) ? "Bundled" : "Inherited";

const promptSections = [
  SectionSpec(
    page: SettingsPageId.agents,
    id: "agents",
    title: "Agents",
    weight: 0,
  ),
  SectionSpec(
    page: SettingsPageId.skills,
    id: "skills",
    title: "Skills",
    weight: 0,
  ),
];

/// What an agent may be granted, listed whatever this device can run: the
/// file means the same on every device it reaches.
final _grantable = [
  for (final tool in agentTools(const ToolOffer()))
    if (tool.group != null) tool,
];

/// An agent written by hand: its name, which is its file's, what it is for,
/// the system prompt, and the tools it is granted, group by group.
class AgentForm extends SettingForm<PromptDocument> {
  AgentForm(this.agent, {required this.taken, this.project});

  final PromptDocument? agent;

  /// Whose library its system prompt completes from.
  final String? project;

  /// Whether a name is another agent's already.
  final bool Function(String name) taken;

  Set<String> get _defaults => {
    for (final tool in _grantable)
      if (tool.onByDefault) tool.id,
  };

  /// The ids switched on to begin with. Ids this build does not know stay,
  /// so a save keeps what a newer build's list named.
  Set<String> get _initialTools => AgentDefinition.of(agent).tools ?? _defaults;

  @override
  String get title => agent == null ? "Add agent" : "Edit ${agent!.name}";

  @override
  bool get page => true;

  @override
  String get discard => "Throw away the edits to this agent?";

  @override
  Map<String, String> get initial => {
    "name": agent?.name ?? "",
    "description": agent?.description ?? "",
    "instructions": agent?.body ?? "",
    for (final group in ToolGroup.values)
      "tools.${group.name}": FormMulti.encode([
        for (final tool in _grantable)
          if (tool.group == group && _initialTools.contains(tool.id)) tool.id,
      ]),
  };

  Set<String> _tools(Map<String, String> a) {
    final picked = <String>{};
    final names = <String>{};
    for (final group in ToolGroup.values) {
      for (final id in FormMulti.decode(a["tools.${group.name}"])) {
        final tool = _grantable.where((t) => t.id == id).firstOrNull;
        // Two tools of one name are one tool worded two ways: the first
        // picked stands.
        if (tool != null && names.add(tool.name)) picked.add(id);
      }
    }
    return picked;
  }

  String? _nameProblem(String name) {
    if (name.isEmpty) return null;
    if (!isFolderName(name)) return "That name cannot be a file name.";
    if (name != agent?.name && taken(name)) {
      return "An agent with that name is already installed.";
    }
    return null;
  }

  @override
  List<FormFieldSpec> fields(Map<String, String> a) => [
    FormText(
      "name",
      "Name",
      hint: "reviewer",
      helper: "What a message calls it: @name.",
      error: _nameProblem(a["name"]!.trim()),
      focused: agent == null,
    ),
    const FormText("description", "Description"),
    FormPrompt(
      "instructions",
      "System prompt",
      hint: "The system prompt the agent runs under.",
      project: project,
    ),
    const FormQuestion("Tools"),
    for (final group in ToolGroup.values)
      if (_grantable.any((t) => t.group == group))
        FormMulti("tools.${group.name}", group.label, all: true, [
          for (final tool in _grantable)
            if (tool.group == group)
              FormOption(
                tool.id,
                tool.id,
                help: tool.description,
                kind: tool.name,
              ),
        ]),
  ];

  @override
  String? problem(Map<String, String> a) {
    final name = a["name"]!.trim();
    if (name.isEmpty || a["instructions"]!.trim().isEmpty) return "";
    return _nameProblem(name) == null ? null : "";
  }

  /// An agent left at the defaults writes no list, so a default added later
  /// reaches it.
  @override
  PromptDocument build(Map<String, String> a) {
    final tools = _tools(a);
    final known = {for (final tool in _grantable) tool.id};
    final unchanged =
        AgentDefinition.of(agent).tools == null &&
        tools.length == _defaults.length &&
        tools.containsAll(_defaults);
    return AgentDefinition.of(agent)
        .edited(
          name: a["name"]!.trim(),
          description: a["description"]!,
          instructions: a["instructions"]!,
          tools: unchanged
              ? null
              : {...tools, ..._initialTools.difference(known)},
        )
        .document!;
  }
}

final promptSettings = [
  SettingSpec(
    id: "agents",
    path: (page: SettingsPageId.agents, section: "agents"),
    weight: 0,
    title: "Agents",
    hint: UiHint.agents,
    build: (c) {
      final (:project, :device) = _whose(c);
      final local = device == null;
      final writable = local && promptsDirUserWritable(project);
      final agents = c.ref
          .watch(promptLibraryOf((device: device, project: project)))
          .entries(CompletionKind.agent);
      // Null while the scan is out: neither the actions nor the badge of an
      // entry is known until it lands.
      final own = local ? c.ref.watch(ownAgentsProvider(project)).value : null;
      final config = c.ref.read(appConfigProvider);
      final handoff = c.ref.read(backupHandoffProvider);
      final files = AgentFiles(config, project: project);
      bool owned(PromptDocument agent) =>
          writable && (own?.contains(agent.name) ?? false);
      return CollectionController<PromptDocument>(
        c.spec,
        items: agents,
        addLabel: "Add agent",
        description: !writable
            ? "System prompts a message can address as @name in this "
                  "project. Shown read-only: the entries are this project's, "
                  "the default project's, or the app's own."
            : agents.isEmpty
            ? "System prompts a message can address as @name. None are "
                  "installed yet."
            : "System prompts a message can address as @name. The bundled "
                  "ones ship with the app; the rest are yours.",
        botAvatar: writable
            ? (index, spec) async {
                await files.setFace(agents[index].name, AgentBot(spec));
                await _reload(c.ref, project);
              }
            : null,
        // A picture is saved as a .png beside the agent's `.md`.
        image: writable
            ? (index, png) async {
                await files.setFace(agents[index].name, AgentPhoto(png));
                await _reload(c.ref, project);
              }
            : null,
        describe: (agent) => CollectionItem(
          agent.name,
          id: agent.name,
          subtitle: agent.description?.nullIfEmpty,
          face: local ? AgentRowFace(project: project, name: agent.name) : null,
          editable: owned(agent),
          takesImage: owned(agent),
          badge: own == null || own.contains(agent.name)
              ? null
              : _origin(CompletionKind.agent, agent.name, project),
          removeLabel: "Remove ${agent.name}",
          actions: [
            if (local) ...[
              const ItemAction("link", "Copy install link"),
              const ItemAction("export", "Export"),
            ],
            if (owned(agent)) ...[
              const ItemAction("removeFace", "Remove picture"),
              ItemAction(
                "remove",
                "Remove",
                destructive: true,
                confirm: SettingConfirm(
                  title: "Remove ${agent.name}?",
                  message:
                      "The agent is deleted. A bundled agent of the same "
                      "name, if there is one, is back the next time the "
                      "library loads.",
                  confirmLabel: "Remove",
                  destructive: true,
                ),
              ),
            ],
          ],
        ),
        form: writable
            ? (agent) => AgentForm(agent, project: project, taken: files.has)
            : null,
        // Removing is the confirmed "remove" action, not the list.
        removable: false,
        submit: (answers, index) async {
          final previous = index == null ? null : agents[index];
          final made = AgentForm(
            previous,
            project: project,
            taken: files.has,
          ).build(answers);
          // The face it has stays, and goes with it under a new name.
          final face = previous == null
              ? null
              : await readOwnAgentFace(config, previous.name, project: project);
          await files.write(
            made.name,
            AgentDefinition.of(made).toSource(),
            removes: previous?.name,
            face: face,
          );
          await _reload(c.ref, project);
        },
        act: (index, action) async {
          final agent = agents[index];
          switch (action) {
            case "link":
              return _link(c.ref, CompletionKind.agent, agent.name, project);
            case "export":
              await exportAndSave(
                config,
                handoff,
                CompletionKind.agent,
                agent.name,
                project: project,
              );
              return null;
            case "removeFace":
              await files.setFace(agent.name, null);
              await _reload(c.ref, project);
              return null;
            case "remove":
              await files.delete(agent.name);
              await _reload(c.ref, project);
              return SettingNotice("Removed ${agent.name}.");
            default:
              return null;
          }
        },
      );
    },
  ),
  SettingSpec(
    id: "importAgent",
    path: (page: SettingsPageId.agents, section: "agents"),
    weight: 10,
    title: "Import agent",
    hint: UiHint.button,
    glyph: SettingGlyph.upload,
    build: (c) {
      final (:project, :device) = _whose(c);
      final files = AgentFiles(c.ref.read(appConfigProvider), project: project);
      ({String name, String source})? read;
      return ActionController(
        c.spec,
        label: "Import agent",
        secondary: true,
        visible: device == null && promptsDirUserWritable(project),
        // An imported `.md` lands under its file's own name, with a
        // replace-confirm where the name is taken.
        confirm: () async {
          read = null;
          final file = await openFile(
            acceptedTypeGroups: const [
              XTypeGroup(label: "Agent", extensions: ["md"]),
            ],
          );
          if (file == null) return const SettingConfirm.nothing();
          String? refused;
          read = AgentFiles.import(
            file.name,
            await file.readAsBytes(),
            refuse: (why) => refused = why,
          );
          if (read == null) return SettingConfirm.note(refused!);
          if (!files.has(read!.name)) return null;
          return SettingConfirm(
            title: "Replace ${read!.name}?",
            message:
                "An agent with that name is already installed. Importing "
                "this one replaces it.",
            confirmLabel: "Replace",
          );
        },
        run: () async {
          final agent = read;
          if (agent == null) return null;
          await files.write(agent.name, agent.source);
          await _reload(c.ref, project);
          return SettingNotice("Imported ${agent.name}.");
        },
      );
    },
  ),
  // The avatar library is this device's, so a paired device's list has no
  // way to it.
  SettingSpec(
    id: "botAvatars",
    path: (page: SettingsPageId.agents, section: "agents"),
    weight: 20,
    title: "View Bot Avatars",
    hint: UiHint.botAvatars,
    glyph: SettingGlyph.person,
    build: (c) {
      final browse = c.ref.read(settingsHandOffProvider).browseBotAvatars;
      return ActionController(
        c.spec,
        label: "View Bot Avatars",
        secondary: true,
        visible: _whose(c).device == null && browse != null,
        run: () async {
          await browse?.call();
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "skills",
    path: (page: SettingsPageId.skills, section: "skills"),
    weight: 0,
    title: "Skills",
    hint: UiHint.skills,
    build: (c) {
      final (:project, :device) = _whose(c);
      final local = device == null;
      final writable = local && promptsDirUserWritable(project);
      final skills = c.ref
          .watch(promptLibraryOf((device: device, project: project)))
          .entries(CompletionKind.skill);
      final own = local ? c.ref.watch(ownSkillsProvider(project)).value : null;
      final loaded = {for (final skill in skills) skill.name};
      // A folder of the project's own the loader skipped is a row of its
      // own, removable, rather than an absence.
      final skipped = [
        for (final name in (own?.keys ?? const <String>[]))
          if (!loaded.contains(name)) name,
      ]..sort();
      final names = [for (final skill in skills) skill.name, ...skipped];
      final config = c.ref.read(appConfigProvider);
      final handoff = c.ref.read(backupHandoffProvider);
      final files = SkillFiles(config, project: project);
      String? origin(String name) => own == null || own.containsKey(name)
          ? null
          : _origin(CompletionKind.skill, name, project);
      return CollectionController<String>(
        c.spec,
        items: names,
        addLabel: "Import skill",
        description: !writable
            ? "What the agent can be told to do by name in this project. "
                  "Shown read-only: the entries are this project's, the "
                  "default project's, or the app's own."
            : "What the agent can be told to do by name. The bundled ones "
                  "ship with the app; the rest are yours.",
        describe: (name) {
          final skill = skills.where((s) => s.name == name).firstOrNull;
          final mine = writable && (own?.containsKey(name) ?? false);
          return CollectionItem(
            name,
            id: name,
            subtitle: skill == null
                ? "Not loaded"
                : skill.description?.nullIfEmpty,
            // What it is wrong about is its page's to say; the row only
            // that there is something.
            glyph: (own?[name] ?? const []).isEmpty
                ? null
                : SettingGlyph.warning,
            tone: NoticeTone.warning,
            badge: origin(name),
            opens: local
                ? SkillPage(
                    name,
                    project: project,
                    origin: skill == null
                        ? "Not loaded"
                        : _origin(CompletionKind.skill, name, project),
                  )
                : null,
            editable: false,
            actions: [
              if (local) ...[
                if (skill != null)
                  const ItemAction("link", "Copy install link"),
                const ItemAction("export", "Export"),
              ],
              if (mine)
                ItemAction(
                  "remove",
                  "Remove",
                  destructive: true,
                  confirm: SettingConfirm(
                    title: "Remove $name?",
                    message:
                        "The skill and its files are deleted. A bundled "
                        "skill of the same name, if there is one, is back "
                        "the next time the library loads.",
                    confirmLabel: "Remove",
                    destructive: true,
                  ),
                ),
            ],
          );
        },
        // Removing is the confirmed "remove" action, not the list.
        removable: false,
        act: (index, action) async {
          final name = names[index];
          switch (action) {
            case "link":
              return _link(c.ref, CompletionKind.skill, name, project);
            case "export":
              await exportAndSave(
                config,
                handoff,
                CompletionKind.skill,
                name,
                project: project,
              );
              return null;
            default:
              await files.delete(name);
              await _reload(c.ref, project);
              return SettingNotice("Removed $name.");
          }
        },
      );
    },
  ),
  // The global page's import can land in any project; a project's own lands
  // in it.
  SettingSpec(
    id: "skillDestination",
    path: (page: SettingsPageId.skills, section: "skills"),
    weight: 5,
    title: "Install to",
    hint: UiHint.dropdown,
    build: (c) {
      final named = c.ref.watch(projectListProvider).value ?? const <String>[];
      final picker = c.ref.read(skillDestinationProvider.notifier);
      return ChoiceController<String?>(
        c.spec,
        visible: c.scope is! ProjectScope,
        options: [
          const SettingOption(null, "Global"),
          for (final project in named)
            SettingOption(project, projectLabel(project)),
        ],
        value: c.ref.watch(skillDestinationProvider),
        onSet: (project) async {
          picker.pick(project);
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "importSkill",
    path: (page: SettingsPageId.skills, section: "skills"),
    weight: 10,
    title: "Import skill",
    hint: UiHint.button,
    glyph: SettingGlyph.upload,
    build: (c) {
      final (:project, :device) = _whose(c);
      final files = SkillFiles(c.ref.read(appConfigProvider));
      final target = c.scope is ProjectScope
          ? project
          : c.ref.watch(skillDestinationProvider);
      SkillPackage? package;
      return ActionController(
        c.spec,
        label: "Import skill",
        secondary: true,
        visible: device == null && promptsDirUserWritable(project),
        confirm: () async {
          package = null;
          final file = await openFile(
            acceptedTypeGroups: const [
              XTypeGroup(label: "Skill", extensions: ["skill", "zip"]),
            ],
          );
          if (file == null) return const SettingConfirm.nothing();
          try {
            package = parseSkillPackage(await file.readAsBytes());
          } on SkillImportException catch (e) {
            return SettingConfirm.note("That file cannot be imported: $e.");
          }
          if (!files.has(package!.name, target: target)) return null;
          return SettingConfirm(
            title: "Replace ${package!.name}?",
            message:
                "A skill with that name is already installed there. "
                "Importing this one replaces it, files included.",
            confirmLabel: "Replace",
          );
        },
        run: () async {
          final skill = package;
          if (skill == null) return null;
          await files.install(skill, target: target);
          await _reload(c.ref, target);
          return SettingNotice(installedSnack("Imported", skill.name, target));
        },
      );
    },
  ),
];

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
