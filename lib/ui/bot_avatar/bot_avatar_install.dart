import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/import.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../providers.dart";
import "../widgets/install_bar.dart";
import "../widgets/page_bar.dart";
import "bot_avatar_editor.dart";
import "bot_avatar_view.dart";

/// Opens what an `entoli://install/avatar` link carried.
Future<void> openBotAvatarInstall(
  BuildContext context,
  BotAvatarImport import,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => BotAvatarInstallPage(import: import)),
);

/// A Bot Avatar a link carried, before it is installed: each definition
/// live in its own colour, or what the reader made of one it refused.
/// Installed into the user's imports, where the editor offers it.
class BotAvatarInstallPage extends ConsumerStatefulWidget {
  const BotAvatarInstallPage({super.key, required this.import});

  final BotAvatarImport import;

  @override
  ConsumerState<BotAvatarInstallPage> createState() =>
      _BotAvatarInstallPageState();
}

class _BotAvatarInstallPageState extends ConsumerState<BotAvatarInstallPage> {
  final _installing = ValueNotifier(false);

  @override
  void dispose() {
    _installing.dispose();
    super.dispose();
  }

  Future<void> _install(BotAvatarImported imported) => runInstall(
    context,
    _installing,
    install: () async {
      await ref
          .read(importedBotAvatarsProvider.notifier)
          .add(imported.definitions);
      return "Installed ${imported.definitions.map((d) => d.name).join(", ")}.";
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final import = widget.import;
    return Scaffold(
      appBar: const PageBar(title: "Install Bot Avatar"),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: switch (import) {
            BotAvatarImportFailed() => BotAvatarImportNotes(import),
            BotAvatarImported(:final definitions) => Column(
              children: [
                Wrap(
                  spacing: 24,
                  runSpacing: 24,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final d in definitions)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 12,
                        children: [
                          BotAvatarView(
                            spec: BotAvatarSpec(
                              definition: d,
                              colour: BotPalette.ownColour(d.id),
                            ),
                            size: definitions.length == 1 ? 200 : 120,
                            reactToTap: true,
                          ),
                          Text(d.name, style: theme.textTheme.titleMedium),
                        ],
                      ),
                  ],
                ),
                if (import.notes.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  BotAvatarImportNotes(import),
                ],
              ],
            ),
          },
        ),
      ),
      bottomNavigationBar: switch (import) {
        final BotAvatarImported imported => ValueListenableBuilder(
          valueListenable: _installing,
          builder: (context, installing, _) => InstallBar(
            installing: installing,
            label: "Install",
            onPressed: () => _install(imported),
          ),
        ),
        _ => null,
      },
    );
  }
}
