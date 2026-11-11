import "package:file_selector/file_selector.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/prompts/prompt_export.dart";
import "../../../data/prompts/skill_import.dart";
import "../../../domain/agent_definition.dart";
import "../../../domain/models.dart";
import "../../../domain/project.dart" show everyProject;
import "../../../domain/prompt_library.dart";
import "../../../providers.dart";
import "../../prompts/agent_files.dart";
import "../../prompts/skill_files.dart";
import "../controller.dart";
import "../spec.dart";

/// The default project's own agents and skills, by name: which entries of
/// the library are the user's to change, the rest bundled. Asked again after
/// every write.
final ownAgentsProvider = FutureProvider<Set<String>>(
  (ref) => AgentFiles(ref.watch(appConfigProvider)).own(),
);

final ownSkillsProvider = FutureProvider<Map<String, List<String>>>(
  (ref) => SkillFiles(ref.watch(appConfigProvider)).own(),
);

/// Re-read every project's library after a change to the default project's,
/// which each of them reads a rung of, and what lists the user's own.
Future<void> _reload(SettingReader ref) async {
  final named = await ref.read(projectListProvider.future);
  await Future.wait(
    everyProject(named).map(
      (project) => ref.read(promptLibraryProvider(project).notifier).reload(),
    ),
  );
  ref.invalidate(ownAgentsProvider);
  ref.invalidate(ownSkillsProvider);
}

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

/// An agent written by hand: its name, which is its file's, what it is for,
/// and the system prompt.
class AgentForm implements SettingForm<PromptDocument> {
  AgentForm(this.agent, {required this.taken});

  final PromptDocument? agent;

  /// Whether a name is another agent's already.
  final bool Function(String name) taken;

  @override
  String get title => agent == null ? "Add agent" : "Edit ${agent!.name}";

  @override
  Map<String, String> get initial => {
    "name": agent?.name ?? "",
    "description": agent?.description ?? "",
    "instructions": agent?.body ?? "",
  };

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
    const FormText("instructions", "System prompt", lines: 8),
  ];

  @override
  String? problem(Map<String, String> a) {
    final name = a["name"]!.trim();
    if (name.isEmpty || a["instructions"]!.trim().isEmpty) return "";
    return _nameProblem(name) == null ? null : "";
  }

  @override
  PromptDocument build(Map<String, String> a) => AgentDefinition.of(agent)
      .edited(
        name: a["name"]!.trim(),
        description: a["description"]!,
        instructions: a["instructions"]!,
        tools: AgentDefinition.of(agent).tools,
      )
      .document!;
}

final promptSettings = [
  SettingSpec(
    id: "agents",
    path: (page: SettingsPageId.agents, section: "agents"),
    weight: 0,
    title: "Agents",
    description:
        "System prompts a message can address as @name. The bundled "
        "ones ship with the app; the rest are yours.",
    hint: UiHint.agents,
    build: (c) {
      final library = c.ref.watch(promptLibraryProvider(null));
      final agents = library.entries(CompletionKind.agent);
      final own = c.ref.watch(ownAgentsProvider).value ?? const {};
      final config = c.ref.read(appConfigProvider);
      final handoff = c.ref.read(backupHandoffProvider);
      final files = AgentFiles(config);
      return CollectionController<PromptDocument>(
        c.spec,
        items: agents,
        addLabel: "Add agent",
        emptyLabel:
            "System prompts a message can address as @name. None are "
            "installed yet.",
        describe: (agent) => CollectionItem(
          agent.name,
          id: agent.name,
          subtitle: agent.description?.nullIfEmpty,
          removeLabel: "Remove ${agent.name}",
          actions: [
            const ItemAction("export", "Export"),
            if (own.contains(agent.name))
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
        ),
        form: (agent) => AgentForm(agent, taken: files.has),
        onSet: (_) async {},
        submit: (answers, index) async {
          final previous = index == null ? null : agents[index];
          final made = AgentForm(previous, taken: files.has).build(answers);
          await files.write(
            made.name,
            AgentDefinition.of(made).toSource(),
            removes: previous?.name,
          );
          await _reload(c.ref);
        },
        act: (index, action) async {
          final agent = agents[index];
          switch (action) {
            case "export":
              await exportAndSave(
                config,
                handoff,
                CompletionKind.agent,
                agent.name,
              );
              return null;
            default:
              await files.delete(agent.name);
              await _reload(c.ref);
              return SettingNotice("Removed ${agent.name}.");
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
      final files = AgentFiles(c.ref.read(appConfigProvider));
      ({String name, String source})? read;
      return ActionController(
        c.spec,
        label: "Import agent",
        secondary: true,
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
          await _reload(c.ref);
          return SettingNotice("Imported ${agent.name}.");
        },
      );
    },
  ),
  SettingSpec(
    id: "skills",
    path: (page: SettingsPageId.skills, section: "skills"),
    weight: 0,
    title: "Skills",
    description:
        "What the agent can be told to do by name. The bundled ones ship "
        "with the app; the rest are yours.",
    hint: UiHint.skills,
    build: (c) {
      final library = c.ref.watch(promptLibraryProvider(null));
      final skills = library.entries(CompletionKind.skill);
      final own = c.ref.watch(ownSkillsProvider).value ?? const {};
      final config = c.ref.read(appConfigProvider);
      final handoff = c.ref.read(backupHandoffProvider);
      final files = SkillFiles(config);
      return CollectionController<PromptDocument>(
        c.spec,
        items: skills,
        addLabel: "Import skill",
        describe: (skill) => CollectionItem(
          skill.name,
          id: skill.name,
          subtitle: skill.description?.nullIfEmpty,
          error: own[skill.name]?.join("; ").nullIfEmpty,
          actions: [
            const ItemAction("export", "Export"),
            if (own.containsKey(skill.name))
              ItemAction(
                "remove",
                "Remove",
                destructive: true,
                confirm: SettingConfirm(
                  title: "Remove ${skill.name}?",
                  message:
                      "The skill and its files are deleted. A bundled skill "
                      "of the same name, if there is one, is back the next "
                      "time the library loads.",
                  confirmLabel: "Remove",
                  destructive: true,
                ),
              ),
          ],
        ),
        onSet: (_) async {},
        act: (index, action) async {
          final skill = skills[index];
          switch (action) {
            case "export":
              await exportAndSave(
                config,
                handoff,
                CompletionKind.skill,
                skill.name,
              );
              return null;
            default:
              await files.delete(skill.name);
              await _reload(c.ref);
              return SettingNotice("Removed ${skill.name}.");
          }
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
      final files = SkillFiles(c.ref.read(appConfigProvider));
      SkillPackage? package;
      return ActionController(
        c.spec,
        label: "Import skill",
        secondary: true,
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
          if (!files.has(package!.name)) return null;
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
          await files.install(skill);
          await _reload(c.ref);
          return SettingNotice(installedSnack("Imported", skill.name, null));
        },
      );
    },
  ),
];

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
