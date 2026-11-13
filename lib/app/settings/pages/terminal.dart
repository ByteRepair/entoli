import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/formatting.dart" show formatSize;
import "../../../domain/confinement.dart";
import "../../../domain/permission.dart";
import "../../../domain/rootfs.dart";
import "../../../domain/sandbox_grant.dart";
import "../../../domain/settings/keys.dart";
import "../../../providers.dart";
import "../../downloads/rootfs_downloads.dart";
import "../controller.dart";
import "../forms/permission_rule.dart";
import "../scope.dart";
import "../spec.dart";

const _page = SettingsPageId.terminal;

/// The default project's: the tier every other project inherits before its
/// own, shown on the app's page beside what it governs.
const _defaultProject = ProjectAddress(null);

bool _hasTerminal(SettingReader ref) =>
    ref.watch(shellProvider.select((s) => s.canRunCommands)) ||
    ref.watch(linuxHostProvider).runsLinux;

/// What the picked driver does about the sandbox: the environment's own
/// answer, with nothing installed falling back to the host's.
Confinement pickedConfinement(SettingReader ref) {
  final selected = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
  final installed = ref.watch(installedRootfsProvider);
  return selected == null || !installed.contains(selected)
      ? ref.watch(hostConfinementProvider)
      : Confinement.guest;
}

final terminalSections = [
  // A phone with no Linux installed has nothing to run, but the catalog
  // below is the way one gets installed, so the section stays for it. A
  // platform with no shell at all gets the header and nothing under it.
  SectionSpec(
    page: _page,
    id: "driver",
    title: "Driver",
    weight: 0,
    keepEmpty: true,
    describe: (ref) {
      if (!_hasTerminal(ref)) {
        return "This platform has no terminal, so the agent has no "
            "commands to run.";
      }
      final linux = ref.watch(linuxHostProvider);
      return "What driver to use when running commands. Determines "
          "the environment commands will run in."
          "${linux.runsLinux ? " Commands run in a Linux installed below; "
                    "with none, the agent has no terminal." : ""}";
    },
  ),
  const SectionSpec(
    page: _page,
    id: "permissions",
    title: "Permissions",
    weight: 10,
    description:
        "Standing rules, consulted before the classifier and "
        "the banner. A deny outranks an ask, which outranks an allow; a "
        "command with segments a rule does not cover still waits.",
  ),
  // Nothing at all where this device could not run a Linux even with one
  // installed: no proot and no in-process emulator.
  SectionSpec(
    page: _page,
    id: "available",
    title: "Available",
    weight: 20,
    description:
        "Downloaded once and kept outside the app's data, so a "
        "backup does not carry it and a restore does not delete it.",
    shown: (ref) => ref.watch(linuxHostProvider).runsLinux,
  ),
];

final terminalSettings = [
  // An APK built without proot staged into it is a build fault and looks
  // exactly like the feature having been removed. The banner names the two
  // commands, since the only person who can reach this is whoever built it.
  SettingSpec(
    id: "missingProot",
    path: (page: _page, section: "driver"),
    weight: 0,
    title: "No proot",
    hint: UiHint.banner,
    glyph: SettingGlyph.warning,
    build: (c) {
      final abi = switch (c.ref.watch(linuxHostProvider)) {
        MissingProotLinux(:final abi) when _hasTerminal(c.ref) => abi,
        _ => null,
      };
      return NoticeController(
        c.spec,
        tone: NoticeTone.warning,
        visible: abi != null,
        lines: [
          NoticeLine(
            "This build has no proot in it for $abi. Run "
            "tool/android/build.sh $abi and "
            "tool/android/stage.sh, then build the APK again.",
          ),
        ],
      );
    },
  ),
  // The picker offers only what is on disk: a choice that fails when it is
  // used rather than when it is made is worse than no choice at all.
  SettingSpec(
    id: "rootfs",
    path: (page: _page, section: "driver"),
    weight: 10,
    title: "Commands run on",
    hint: UiHint.installed,
    build: (c) {
      final linux = c.ref.watch(linuxHostProvider);
      final installed = c.ref.watch(installedRootfsProvider);
      return ChoiceController<String>(
        c.spec,
        options: [
          for (final rootfs in linux.catalog)
            if (linux.runsLinux && installed.contains(rootfs.id))
              SettingOption(rootfs.id, rootfs.name),
        ],
        value: c.scope.resolve(SettingKeys.rootfsId),
        // A phone offers no shell of its own, so nothing picked is no
        // terminal rather than an entry. On a desktop it is the machine's
        // own shell, an answer.
        noneLabel: linux.hasHostShell ? "Host" : null,
        visible: _hasTerminal(c.ref),
        onSet: (id) async {
          await c.ref.read(appSettingsProvider.notifier).setRootfs(id);
          return null;
        },
      );
    },
  ),
  // The one place the sandbox policy is shown: whether the picked driver can
  // enforce one, and whether the default project's switch lets it.
  SettingSpec(
    id: "sandboxStatus",
    path: (page: _page, section: "driver"),
    weight: 20,
    title: "Sandbox",
    hint: UiHint.card,
    at: _defaultProject,
    build: (c) {
      final supported = pickedConfinement(c.ref).enforcesSandbox;
      final enabled = c.scope.own(SettingKeys.sandbox) ?? true;
      final (tone, text) = !supported
          ? (
              NoticeTone.warning,
              "This environment does not support sandboxing. Sandbox is not "
                  "enforced.",
            )
          : !enabled
          ? (
              NoticeTone.warning,
              "This environment supports sandboxing, but it is disabled. "
                  "Enable it in Settings > Terminal > Sandbox.",
            )
          : (NoticeTone.good, "Sandboxing is enforced.");
      return NoticeController(c.spec, tone: tone, lines: [NoticeLine(text)]);
    },
  ),
  SettingSpec(
    id: "permissions",
    path: (page: _page, section: "permissions"),
    weight: 0,
    title: "Permissions",
    hint: UiHint.row,
    at: _defaultProject,
    build: (c) => CollectionController<PermissionRule>(
      c.spec,
      items: c.scope.own(SettingKeys.permissions) ?? const [],
      addLabel: "Add rule",
      removeLabel: "Remove rule",
      describe: describeRule,
      form: PermissionRuleForm.new,
      onSet: (rules) => c.scope.write(SettingKeys.permissions, rules),
    ),
  ),
  SettingSpec(
    id: "sandbox",
    path: (page: _page, section: "permissions"),
    weight: 10,
    title: "Sandbox",
    description:
        "Commands may write only to the workspaces and the directories "
        "granted. A project can override this.",
    hint: UiHint.toggle,
    at: _defaultProject,
    build: (c) => ToggleController(
      c.spec,
      value: c.scope.own(SettingKeys.sandbox),
      effective: c.scope.own(SettingKeys.sandbox) ?? true,
      onSet: (value) async {
        await c.scope.write(SettingKeys.sandbox, value);
        return null;
      },
    ),
  ),
  // The folders granted beside the workspaces that nobody named: a toggle
  // each, not a work folder, since they are the app's defaults rather than
  // the user's additions.
  for (final (i, grant) in SandboxGrant.values.indexed)
    SettingSpec(
      id: grant.settingId,
      path: (page: _page, section: "permissions"),
      weight: 11 + i,
      title: grant.title,
      description: grant.description,
      hint: UiHint.toggle,
      at: _defaultProject,
      build: (c) => ToggleController(
        c.spec,
        value: c.scope.own(grant.setting),
        effective: c.scope.resolve(grant.setting) ?? true,
        onSet: (value) async {
          await c.scope.write(grant.setting, value);
          return null;
        },
      ),
    ),
  // One row per distribution, with the single thing that can be done to it
  // now. An architecture with no image is a row drawn dead.
  SettingSpec(
    id: "rootfsCatalog",
    path: (page: _page, section: "available"),
    weight: 0,
    title: "Available",
    hint: UiHint.row,
    build: (c) {
      final linux = c.ref.watch(linuxHostProvider);
      final downloads = c.ref.watch(rootfsDownloadsProvider);
      final installed = c.ref.watch(installedRootfsProvider);
      final picked = c.scope.resolve(SettingKeys.rootfsId);
      final notifier = c.ref.read(rootfsDownloadsProvider.notifier);
      Rootfs byId(String id) => linux.catalog.firstWhere((r) => r.id == id);
      return CatalogController(
        c.spec,
        items: [
          for (final rootfs in linux.catalog)
            if (rootfs.imageFor(linux.imageKey) case final image)
              CatalogItem(
                id: rootfs.id,
                title: "${rootfs.name} ${rootfs.version}",
                summary: image == null
                    ? "No build for this device"
                    : "${image.arch} · ${formatSize(image.bytes)} to "
                          "download · ${rootfs.packageManager} for everything "
                          "else",
                failure: downloads.failures[rootfs.id],
                progress: downloads.active[rootfs.id],
                installed: installed.contains(rootfs.id),
                downloadable: image != null,
                // What it costs to agree depends on whether commands are
                // running in it.
                deleteConfirm: SettingConfirm(
                  title: "Delete ${rootfs.name}?",
                  message: picked == rootfs.id
                      ? "Everything installed in it goes with it, and the "
                            "agent has no terminal until a Linux is installed "
                            "again."
                      : "Everything installed in it goes with it.",
                  confirmLabel: "Delete",
                  destructive: true,
                ),
              ),
        ],
        download: (id) async => notifier.install(byId(id)),
        cancel: (id) async => notifier.cancel(id),
        delete: (id) => notifier.delete(byId(id)),
      );
    },
  ),
];
