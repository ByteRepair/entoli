import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/brand.dart" show madeBy;
import "../../providers.dart";
import "../app_command.dart";
import "../theme.dart" show appTitle;
import "../widgets/app_mark.dart";
import "../widgets/section_header.dart";
import "privacy_policy_page.dart";

final _repository = Uri.parse("https://github.com/ByteRepair/entoli");

/// What this build is, who made it, and where the source is. The libraries are
/// Flutter's own licence page rather than a list kept here — see "What the app
/// is".
class AboutSettings extends ConsumerWidget {
  const AboutSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider);
    return ListView(
      children: [
        const SectionHeader("About"),
        ListTile(
          leading: const AppMark(size: 40),
          title: const Text(appTitle),
          subtitle: version == null ? null : Text("Version $version"),
        ),
        const ListTile(
          leading: Icon(Icons.person_outline),
          title: Text(madeBy),
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text("Source on GitHub"),
          subtitle: Text("$_repository"),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => ref.read(linkOpenerProvider).open(context, _repository),
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text("Privacy policy"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PrivacyPolicyPage())),
        ),
        ListTile(
          leading: const Icon(Icons.balance_outlined),
          title: const Text("Open source libraries"),
          subtitle: const Text(
            "Everything Entoli is built on, and its licence.",
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: appTitle,
            applicationVersion: version,
            applicationIcon: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: AppMark(size: 48),
            ),
            applicationLegalese: madeBy,
          ),
        ),
      ],
    );
  }
}

/// The keyboard shortcuts, on every platform: a phone or tablet can have a
/// keyboard attached, and then they work there too.
class ShortcutsSettings extends StatelessWidget {
  const ShortcutsSettings({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const SectionHeader("Keyboard shortcuts"),
      for (final item in appItems)
        if (item.key case final key?)
          ListTile(title: Text(item.title), trailing: _Keys(key.caps)),
    ],
  );
}

/// A chord's keys, each on a cap of its own.
class _Keys extends StatelessWidget {
  const _Keys(this.caps);

  final List<String> caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        for (final cap in caps)
          Container(
            constraints: const BoxConstraints(minWidth: 28),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              cap,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium,
            ),
          ),
      ],
    );
  }
}
