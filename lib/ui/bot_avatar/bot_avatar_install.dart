import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/import.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart";
import "bot_avatar_view.dart";
import "../widgets/install_bar.dart";
import "../widgets/page_bar.dart";

/// A Bot Avatar an `entoli://install/avatar` link carried: the bot, and
/// Install under it. Installing is the editor's import, landing in the same
/// library.
class BotAvatarInstallPage extends ConsumerStatefulWidget {
  const BotAvatarInstallPage({super.key, required this.import});

  final BotAvatarImport import;

  @override
  ConsumerState<BotAvatarInstallPage> createState() =>
      _BotAvatarInstallPageState();
}

class _BotAvatarInstallPageState extends ConsumerState<BotAvatarInstallPage> {
  var _installing = false;

  Future<void> _install(BotAvatarImported imported) async {
    setState(() => _installing = true);
    await ref
        .read(importedBotAvatarsProvider.notifier)
        .add(imported.definitions);
    if (!mounted) return;
    say(
      context,
      "Installed ${imported.definitions.map((d) => d.name).join(", ")}.",
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const PageBar(title: "Install Bot Avatar"),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: switch (widget.import) {
            BotAvatarImported(:final definitions) => Wrap(
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
            BotAvatarImportFailed(:final errors) => Text(
              "This link's Bot Avatar does not fit the spec:\n"
              "${errors.join("\n")}",
              style: TextStyle(color: theme.colorScheme.error),
            ),
          },
        ),
      ),
      bottomNavigationBar: switch (widget.import) {
        final BotAvatarImported imported => InstallBar(
          installing: _installing,
          label: "Install",
          onPressed: () => _install(imported),
        ),
        BotAvatarImportFailed() => null,
      },
    );
  }
}
