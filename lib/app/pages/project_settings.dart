import "dart:io";

import "../../domain/builtin_project.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../domain/sandbox_grant.dart";
import "../../domain/settings/keys.dart";
import "../../domain/shell.dart" show isTildePath;
import "../../domain/tristate.dart";
import "../../domain/work_folders.dart";
import "../../providers.dart";
import "../selection.dart";
import "../settings/controller.dart";
import "../settings/pages/terminal.dart" show pickedConfinement;
import "../settings/scope.dart";
import "../settings/spec.dart";
import "app_page.dart";
import "memory.dart";
import "profile.dart";
import "workspace.dart";

/// Deletes [project], its chats and its shared workspace, and lets go of
/// every reference to it: the selection, the assistant's project and the
/// linked instruction files. Shared by every place a project is deleted, so
/// what goes with it is said once.
Future<void> deleteProjectNamed(SettingReader app, String project) async {
  await app.read(chatRepositoryProvider).deleteProject(project);
  app.read(selectedProjectProvider.notifier).switchTo(localProject(null));
  // Left written down, the next save would write it back, and a project made
  // again under the name would pick it up.
  if (app.read(appSettingsProvider).assistantProject == project) {
    await app.read(appSettingsProvider.notifier).setAssistantProject(null);
  }
  await app
      .read(linkedInstructionsStoreProvider)
      .update((l) => l.withoutProject(project));
  app.invalidate(projectListProvider);
  app.invalidate(chatListProvider);
}

/// What deleting [project] with its [count] chats asks.
String deleteProjectMessage(String project, int count) =>
    "Delete \"$project\", its $count ${count == 1 ? "chat" : "chats"} "
    "and its shared workspace? This cannot be undone.";

/// A project's settings: what it is, what its turns are told and may do,
/// its memory, its rounds and how long its chats live, and deleting it. A
/// paired device's project is read from there and written there, and is
/// read only while the device is away.
class ProjectSettingsAppPage extends AppPage {
  ProjectSettingsAppPage(this.project, {this.device});

  final String project;
  final String? device;

  ProjectRef get at => (device: device, project: project);
  bool get remote => device != null;

  @override
  String get address => "project-settings/${device ?? ""}/$project";

  @override
  String title(SettingReader reader) => "Project Settings";

  @override
  String? subtitle(SettingReader reader) => projectLabel(project);

  ProjectScope _scope(SettingReader reader) =>
      projectScopeAt(reader, ProjectAddress(project, device: device));

  int _count(SettingReader reader) => remote
      ? reader
            .watch(remoteChatsProvider)
            .where((c) => c.deviceId == device && c.state.project == project)
            .length
      : (reader.watch(chatListProvider).value ?? const [])
            .where((c) => c.project == project)
            .length;

  @override
  List<PageSection> sections(SettingReader reader) {
    if (reader.watch(projectGoneProvider(at))) {
      return [notice("gone", "This project is no longer on that device.")];
    }
    if (!reader.watch(projectLoadedProvider(at))) {
      return [notice("loading", "Reading the project's settings…")];
    }
    final frozen = reader.watch(projectFrozenProvider(at));
    final builtIn = builtinProjectOf(project);
    final scope = _scope(reader);
    final config = reader.watch(appConfigProvider);
    final settings = reader.watch(projectSettingsOf(at));
    final omada = builtIn?.omada ?? settings.omada;
    final sections = [
      if (remote) deviceNotice("project", _deviceName(reader), online: !frozen),
      PageSection("project", "", [
        ActionController(
          part("name", "Project name", description: project),
          label: "Copy",
          run: () async => SettingNotice("Copied project name", copy: project),
        ),
        if (!remote)
          ActionController(
            part(
              "path",
              "Path",
              description: config.projectDir(project: project),
            ),
            label: "Copy",
            run: () async => SettingNotice(
              "Copied project path",
              copy: config.projectDir(project: project),
            ),
          ),
        // What the new-chat screen asks over the project's badge: empty asks
        // nothing, and clearing it is the way back to the app's question.
        if (builtIn == null)
          TextController(
            part(
              "description",
              "Description",
              hint: UiHint.row,
              description: projectDescriptionHelp,
            ),
            value: settings.description ?? "",
            emptyLabel:
                emptyChatQuestionFor(
                  project,
                  description: settings.description,
                ) ??
                "Empty",
            prompt: defaultEmptyChatQuestion,
            lines: 3,
            allowBlank: true,
            // Blank is an answer of its own, the screen asking nothing; the
            // way back to the app's question is this.
            accessory: ActionController(
              part(
                "descriptionReset",
                "Use the Default Question",
                glyph: SettingGlyph.tune,
              ),
              enabled: settings.description != null,
              run: () async {
                await app
                    .read(projectSettingsOf(at).notifier)
                    .setDescription(null);
                return null;
              },
            ),
            onSet: (text) async {
              await app
                  .read(projectSettingsOf(at).notifier)
                  .setDescription(text);
              return null;
            },
          ),
        if (!remote)
          opener(
            "workspace",
            "Workspace",
            () => WorkspaceAppPage(
              root: config.projectWorkspaceDir(project: project),
              owner: "Project workspace",
            ),
            description: "Browse files",
            glyph: SettingGlyph.folder,
          ),
        InfoController(
          part("chats", "Chats", hint: UiHint.info),
          rows: [
            InfoRow(
              "Chats",
              subtitle: "${_count(reader)}",
              glyph: SettingGlyph.chat,
            ),
          ],
        ),
      ]),
      PageSection("library", "What its turns are told", [
        if (!remote &&
            (builtIn?.bundledInstructions == null ||
                builtIn?.includesUserInstructions == true))
          opener(
            "instructions",
            "Instructions",
            () => ProfileAppPage(project: project),
            label:
                File(
                  config.projectInstructionsFile(project: project),
                ).existsSync()
                ? "Set"
                : "Not set",
            glyph: SettingGlyph.edit,
          ),
        for (final kind in CompletionKind.values)
          opener(
            kind.name,
            kind.label,
            () => SettingsAppPage(
              switch (kind) {
                CompletionKind.skill => SettingsPageId.skills,
                CompletionKind.agent => SettingsPageId.agents,
              },
              ProjectAddress(project, device: device),
              label: kind.label,
              sub: projectLabel(project),
            ),
            label: switch (reader
                .watch(promptLibraryOf(at))
                .entries(kind)
                .length) {
              0 => "None",
              final n => "$n",
            },
            glyph: kind == CompletionKind.skill
                ? SettingGlyph.skill
                : SettingGlyph.agent,
          ),
      ]),
      PageSection("commands", "Commands", [
        shared(reader, scope, "environment"),
        shared(reader, scope, "permissions"),
        shared(reader, scope, "sandbox"),
        for (final grant in SandboxGrant.values)
          shared(reader, scope, grant.settingId),
      ]),
      // Folders on this machine, granted to the host's sandbox: not a paired
      // device's, and not where nothing is confined.
      if (!remote && pickedConfinement(reader).enforcesSandbox)
        PageSection(
          "folders",
          "Work folders",
          [_workFolders(reader, settings.writableDirs)],
          detail:
              "Folders outside the workspace that this project's commands may "
              "write to, with nothing to approve.",
        ),
      if (builtIn == null)
        PageSection("memory", "Memory", [
          ChoiceController<Tristate>(
            part("memory", "Project memory", hint: UiHint.segmented),
            options: const [
              SettingOption(Tristate.off, "Off"),
              SettingOption(Tristate.inherit, "Shared"),
              SettingOption(Tristate.on, "Own"),
            ],
            value: settings.memory,
            description: switch (settings.memory) {
              Tristate.off => "This project's chats have no memory.",
              Tristate.inherit =>
                "This project's chats share the default project's memories.",
              Tristate.on => "This project keeps memories of its own.",
            },
            onSet: (value) async {
              await app
                  .read(projectSettingsOf(at).notifier)
                  .setMemory(value ?? Tristate.inherit);
              return null;
            },
          ),
          opener(
            "memories",
            "Memories",
            () => MemoryAppPage(project: at, owner: "Project memories"),
            description: "Browse, add, pin, delete",
            glyph: SettingGlyph.memory,
          ),
        ]),
      PageSection("rounds", "Rounds", [
        // A built-in's answer is its spec: the state shown, not offered.
        ToggleController(
          part(
            "omada",
            "Omada",
            hint: UiHint.toggle,
            description:
                "Several named agents take part in a chat's replies, "
                "alongside the main one.",
          ),
          value: omada,
          effective: omada,
          enabled: builtIn == null,
          onSet: (on) async {
            await app
                .read(projectSettingsOf(at).notifier)
                .setOmada(on ?? false);
            return null;
          },
        ),
        if (omada) ...[
          shared(reader, scope, "omadaOrdering"),
          shared(reader, scope, "omadaMaxGenerations"),
        ],
        // A turn is a turn in every project, built-ins included.
        shared(reader, scope, "turnMaxSteps"),
      ]),
      PageSection("temporary", "Temporary chats", [
        tempTtlChoice(
          "Delete chats after",
          value: scope.own(SettingKeys.tempChatTtl),
          // What `ChatRepository._resolveTempTtl` falls to below this level.
          inherited: inheritedTempTtl(
            project,
            app: scope.inherited(SettingKeys.tempChatTtl)!,
          ),
          // The notifier's setter, which a remote project's sends to its
          // device.
          onSet: (ttl) =>
              app.read(projectSettingsOf(at).notifier).setTempChatTtl(ttl),
        ),
      ]),
      if (builtIn == null)
        PageSection("delete", "", [
          ActionController(
            part("delete", "Delete Project", hint: UiHint.button),
            destructive: true,
            confirm: () async => SettingConfirm(
              title: "Delete project?",
              // Counted once the list is read, not from what was drawn.
              message: deleteProjectMessage(
                project,
                remote
                    ? _count(app)
                    : (await app.read(
                        chatListProvider.future,
                      )).where((c) => c.project == project).length,
              ),
              confirmLabel: "Delete",
              destructive: true,
            ),
            run: _delete,
          ),
        ]),
    ];
    // What the device last said, readable and not written until it is back.
    return frozen ? [for (final s in sections) _readOnly(s)] : sections;
  }

  String _deviceName(SettingReader reader) =>
      reader.watch(syncPeersProvider)[device]?.name ?? "The device";

  /// [section] as it is drawn while the device is away: what is shown, with
  /// nothing to change.
  PageSection _readOnly(PageSection section) =>
      PageSection(section.id, section.title, [
        for (final c in section.controllers)
          if (c is NoticeController || c is InfoController) c else _disabled(c),
      ], detail: section.detail);

  SettingController _disabled(SettingController c) => switch (c) {
    ActionController() => ActionController(
      c.spec,
      label: c.label,
      run: c.run,
      enabled: false,
      title: c.title,
      description: c.description,
    ),
    _ => NoticeController(
      c.spec,
      title: c.title,
      lines: [if (c.description case final d?) NoticeLine(d)],
    ),
  };

  SettingController _workFolders(SettingReader reader, List<String> dirs) {
    FolderRefusal? refusal(String dir) => refuseFolder(
      dir,
      dataDir: reader.read(appConfigProvider).dataDir,
      home: reader.read(shellProvider).machineHome,
      workspaces: [
        reader.read(appConfigProvider).projectWorkspaceDir(project: project),
      ],
    );
    final notifier = app.read(projectSettingsOf(at).notifier);
    return GroupController(
      part("folders", "Work folders", hint: UiHint.info),
      children: [
        CollectionController<String>(
          part("folderList", "Work folders", hint: UiHint.info),
          items: dirs,
          removeLabel: "Remove",
          emptyLabel: "No folders yet.",
          // One the turn is not granted is said rather than left looking
          // live; a `~` path is the turn's to resolve.
          describe: (dir) => CollectionItem(
            dir,
            subtitle: isTildePath(dir) ? null : refusal(dir)?.row,
            glyph: SettingGlyph.folder,
            editable: false,
            takesImage: false,
          ),
          onSet: notifier.setWritableDirs,
        ),
        // Folders come from the platform's picker, never typed.
        ActionController(
          part("addFolder", "Add Folder…", glyph: SettingGlyph.add),
          run: () async {
            final picked = await app
                .read(folderPickerProvider)
                .pick(confirmLabel: "Add");
            if (picked == null) return null;
            if (refusal(picked) case final refused?) {
              return SettingNotice(refused.message);
            }
            final now = app.read(projectSettingsOf(at)).writableDirs;
            if (!now.contains(picked)) {
              await notifier.setWritableDirs([...now, picked]);
            }
            return null;
          },
        ),
      ],
    );
  }

  Future<SettingNotice?> _delete() async {
    if (remote) {
      if (!await app
          .read(syncHubProvider)
          .deleteRemoteProject(device!, project)) {
        return const SettingNotice("The project was not deleted there.");
      }
      app.read(selectedProjectProvider.notifier).switchTo((
        device: device,
        project: null,
      ));
      pages.closeAll();
      return null;
    }
    pages.closeAll();
    await deleteProjectNamed(app, project);
    return null;
  }
}

/// A page of the settings at a level other than the app's: a project's own
/// skills or agents.
class SettingsAppPage extends AppPage {
  SettingsAppPage(this.page, this.at, {required this.label, this.sub});

  final SettingsPageId page;
  final ScopeAddress at;
  final String label;
  final String? sub;

  @override
  String get address => "settings/${page.name}/${at.hashCode}";

  @override
  String title(SettingReader reader) => label;

  @override
  String? subtitle(SettingReader reader) => sub;

  @override
  List<PageSection> sections(SettingReader reader) =>
      settingsPage(reader, page, at);
}
