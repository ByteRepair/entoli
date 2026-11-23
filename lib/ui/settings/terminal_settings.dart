import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/downloads/rootfs_downloads.dart";
import "../../app/settings/confinement.dart";
import "../../app/settings/scope.dart";
import "package:entoli_chat/core/formatting.dart";
import "package:entoli_chat/domain/rootfs.dart";
import "package:entoli_chat/domain/sandbox_grant.dart";
import "package:entoli_chat/domain/settings/keys.dart";
import "package:entoli_chat/domain/settings/setting.dart";
import "../../providers.dart";
import "package:entoli_chat/ui/widgets/busy.dart";
import "../widgets/catalog.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/settings_warning_banner.dart";
import "permissions_section.dart";
import "scoped.dart";

/// The default project's: the tier every other project inherits before its
/// own, shown on the app's page beside what it governs.
const _defaultProject = ProjectAddress(null);

/// The Terminal category: where commands run, whether they are sandboxed,
/// the default project's rules, and the Linux catalog.
class TerminalSettings extends StatelessWidget {
  const TerminalSettings({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    children: const [
      TerminalSection(),
      SandboxStatusCard(),
      Divider(),
      PermissionRulesSection(
        at: _defaultProject,
        description:
            "Standing rules, consulted before the classifier and "
            "the banner. A deny outranks an ask, which outranks an allow; a "
            "command with segments a rule does not cover still waits.",
      ),
      SandboxSettings(at: _defaultProject),
      // Draws its own divider, since a build with no proot in it has no
      // catalog to put under one.
      RootfsCatalogSection(),
    ],
  );
}

/// Where the agent's commands run: the host driver, or, where this build
/// ships proot or an emulator, a Linux installed from the catalog. The
/// picker offers only what is on disk: a choice that fails when it is used
/// rather than when it is made is worse than no choice at all.
class TerminalSection extends ConsumerWidget {
  const TerminalSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canRun = ref.watch(shellProvider.select((s) => s.canRunCommands));
    final linux = ref.watch(linuxHostProvider);
    // A phone with no Linux installed has nothing to run, but the catalog
    // below is the way one gets installed, so the section stays for it.
    if (!canRun && !linux.runsLinux) {
      return SectionHeader(
        "Driver",
        description:
            "This platform has no terminal, so the agent has no "
            "commands to run.",
      );
    }
    final installed = ref.watch(installedRootfsProvider);
    final selected = ref.watch(appSettingsProvider.select((s) => s.rootfsId));
    final unpackagedAbi = switch (linux) {
      MissingProotLinux(:final abi) => abi,
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Driver",
          description:
              "What driver to use when running commands. Determines "
              "the environment commands will run in."
              "${linux.runsLinux ? " Commands run in a Linux installed below; "
                        "with none, the agent has no terminal." : ""}",
        ),
        // An APK built without proot looks exactly like the feature having
        // been removed. Only whoever built it can reach this, so the banner
        // names the two commands.
        if (unpackagedAbi != null)
          SettingsWarningBanner(
            icon: Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error,
            text:
                "This build has no proot in it for $unpackagedAbi. Run "
                "tool/android/build.sh $unpackagedAbi and "
                "tool/android/stage.sh, then build the APK again.",
          ),
        InstalledPicker(
          label: "Commands run on",
          // A phone offers no shell of its own, so nothing picked is no
          // terminal rather than an entry. On a desktop it is the machine's
          // own shell, an answer.
          none: linux.hasHostShell ? "Host" : null,
          options: {
            for (final rootfs in linux.catalog)
              if (linux.runsLinux && installed.contains(rootfs.id))
                rootfs.id: rootfs.name,
          },
          value: selected,
          onPick: (id) => guarded(
            context,
            () => ref.read(appSettingsProvider.notifier).setRootfs(id),
          ),
        ),
      ],
    );
  }
}

/// The one place the sandbox policy is shown: whether the picked driver can
/// enforce one, and whether the default project's switch lets it.
class SandboxStatusCard extends ConsumerWidget {
  const SandboxStatusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final supported = ref.watch(pickedConfinementProvider).enforcesSandbox;
    final enabled =
        scopeOf(ref, _defaultProject).own(SettingKeys.sandbox) ?? true;
    final (icon, colour, text) = !supported
        ? (
            Icons.warning_amber_rounded,
            scheme.error,
            "This environment does not support sandboxing. Sandbox is not "
                "enforced.",
          )
        : !enabled
        ? (
            Icons.warning_amber_rounded,
            scheme.error,
            "This environment supports sandboxing, but it is disabled. "
                "Enable it in Settings > Terminal > Sandbox.",
          )
        : (Icons.shield_outlined, scheme.primary, "Sandboxing is enforced.");
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: ListTile(
        leading: Icon(icon, color: colour),
        title: Text(text),
      ),
    );
  }
}

/// The sandbox switch at [at], and a switch for each folder granted beside
/// the workspaces that nobody named, where [at] holds them: a chat holds
/// only the sandbox. The default project's are plain switches, the tier
/// every project inherits; a project's or a chat's inherit what is above
/// them until set.
class SandboxSettings extends ConsumerWidget {
  const SandboxSettings({super.key, required this.at});

  final ScopeAddress at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    final base = scope is ProjectScope && scope.project == null;
    final sandboxed = scope.resolve(SettingKeys.sandbox) ?? true;
    final chat = scope is ChatScope;
    Widget toggle(Setting<bool> setting, String title, String? subtitle) {
      void set(bool? value) =>
          guarded(context, () => scope.write(setting, value));
      if (base) {
        return SwitchListTile(
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          value: scope.own(setting) ?? true,
          onChanged: set,
        );
      }
      return InheritableSwitch(
        title: title,
        subtitle: subtitle,
        value: scope.own(setting),
        inherited: scope.inherited(setting) ?? true,
        onChanged: set,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        toggle(
          SettingKeys.sandbox,
          "Sandbox",
          base
              ? "Commands may write only to the workspaces and the "
                    "directories granted. A project can override this."
              : sandboxed
              ? null
              : chat
              ? "Off: this chat's commands write wherever you can."
              : "Off: commands write wherever you can.",
        ),
        if (!chat)
          for (final grant in SandboxGrant.values)
            toggle(grant.setting, grant.title, grant.description),
      ],
    );
  }
}

/// The catalog, or nothing at all where this device could not run a Linux
/// even with one installed.
class RootfsCatalogSection extends ConsumerWidget {
  const RootfsCatalogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linux = ref.watch(linuxHostProvider);
    if (!linux.runsLinux) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SectionHeader(
          "Available",
          description:
              "Downloaded once and kept outside the app's data, so a "
              "backup does not carry it and a restore does not delete it.",
        ),
        for (final rootfs in linux.catalog) RootfsTile(rootfs: rootfs),
      ],
    );
  }
}

/// One distribution as a row: what it is, what it costs, and the single
/// button that applies to it — download, cancel, or delete.
class RootfsTile extends ConsumerWidget {
  const RootfsTile({super.key, required this.rootfs});

  final Rootfs rootfs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its own row only: a progress event names one distribution, and
    // watching the whole state would rebuild every tile for it.
    final progress = ref.watch(
      rootfsDownloadsProvider.select((s) => s.active[rootfs.id]),
    );
    final failure = ref.watch(
      rootfsDownloadsProvider.select((s) => s.failures[rootfs.id]),
    );
    final image = rootfs.imageFor(ref.watch(linuxHostProvider).imageKey);
    return CatalogTile(
      title: Text("${rootfs.name} ${rootfs.version}"),
      summary: image == null
          ? "No build for this device"
          : "${image.arch} · ${formatSize(image.bytes)} to download · "
                "${rootfs.packageManager} for everything else",
      failure: failure,
      progress: progress,
      trailing: _Action(rootfs: rootfs, downloading: progress != null),
    );
  }
}

/// Reads the installed set and the host itself, so a change to either
/// rebuilds the button rather than the row.
class _Action extends ConsumerWidget {
  const _Action({required this.rootfs, required this.downloading});

  final Rootfs rootfs;
  final bool downloading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.read(rootfsDownloadsProvider.notifier);
    return CatalogAction(
      downloading: downloading,
      installed: ref.watch(installedRootfsProvider).contains(rootfs.id),
      onCancel: () => downloads.cancel(rootfs.id),
      onDelete: () => guarded(context, () => downloads.delete(rootfs)),
      deleteTitle: "Delete ${rootfs.name}?",
      // What it costs to agree depends on whether commands are running in
      // it.
      deleteMessage:
          ref.watch(appSettingsProvider.select((s) => s.rootfsId)) == rootfs.id
          ? "Everything installed in it goes with it, and the agent has no "
                "terminal until a Linux is installed again."
          : "Everything installed in it goes with it.",
      // An architecture with no image is a row drawn dead rather than left
      // out, so the reader can see the distribution exists.
      onDownload: rootfs.imageFor(ref.watch(linuxHostProvider).imageKey) == null
          ? null
          : () => downloads.install(rootfs),
    );
  }
}
