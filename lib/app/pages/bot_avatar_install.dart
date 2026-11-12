import "../../domain/bot_avatar/definition.dart";
import "../../domain/bot_avatar/import.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../providers.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A Bot Avatar a link carried, before it is installed: each definition
/// live in its own colour, or what the reader made of a definition it
/// refused. Installed into the user's imports, where the editor offers it.
class BotAvatarInstallAppPage extends AppPage {
  BotAvatarInstallAppPage(this.import);

  final BotAvatarImport import;

  @override
  String get address => "bot-avatar-install/${import.hashCode}";

  @override
  String title(SettingReader reader) => "Install Bot Avatar";

  @override
  List<PageSection> sections(SettingReader reader) => switch (import) {
    BotAvatarImportFailed(:final errors, :final hints, :final notes) => [
      PageSection("failed", "This avatar could not be read", [
        NoticeController(
          part("errors", ""),
          tone: NoticeTone.warning,
          lines: [for (final e in errors) NoticeLine(e)],
        ),
        if (hints.isNotEmpty || notes.isNotEmpty)
          NoticeController(
            part("hints", ""),
            lines: [
              for (final h in hints) NoticeLine("• $h"),
              for (final n in notes) NoticeLine(n),
            ],
          ),
      ]),
    ],
    BotAvatarImported(:final definitions, :final notes) => [
      PageSection("avatars", "", [
        CollectionController<BotAvatarDefinition>(
          part("avatars", "Avatars", hint: UiHint.info),
          items: definitions,
          removable: false,
          describe: (d) => CollectionItem(
            d.name,
            bot: BotAvatarSpec(
              definition: d,
              colour: BotPalette.ownColour(d.id),
            ),
            editable: false,
            takesImage: false,
          ),
        ),
        if (notes.isNotEmpty)
          NoticeController(
            part("notes", ""),
            lines: [for (final n in notes) NoticeLine(n)],
          ),
      ]),
    ],
  };

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    if (import case BotAvatarImported(:final definitions))
      ActionController(
        part("install", "Install"),
        label: "Install",
        run: () async {
          await app.read(importedBotAvatarsProvider.notifier).add(definitions);
          app.read(appPagesProvider.notifier).leave(this);
          return SettingNotice(
            "Installed ${definitions.map((d) => d.name).join(", ")}.",
          );
        },
      ),
  ];
}
