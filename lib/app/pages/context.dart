import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../mirror_controller.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// What fills each participant's context window, out of the model's whole,
/// and where auto-compact steps in: a row per participant, its face and how
/// full it is, with what fills it under it.
class ContextAppPage extends AppPage {
  ContextAppPage(this.chatId, {this.project});

  final String chatId;

  /// Where a participant's face is looked up.
  final String? project;

  @override
  String get address => "context/$chatId";

  @override
  String title(SettingReader reader) => "Context";

  static String _k(int tokens) => tokens < 1000
      ? "$tokens"
      : tokens < 10000
      ? "${(tokens / 1000).toStringAsFixed(1)}k"
      : "${(tokens / 1000).round()}k";

  @override
  List<PageSection> sections(SettingReader reader) {
    final contexts =
        reader
            .watch(chatViewProvider(chatId).select((s) => s.chat))
            ?.contexts ??
        const <String, ContextUsage>{};
    final settings = reader.watch(appSettingsProvider);
    final window =
        reader.watch(contextWindowProvider(chatId)).value ??
        settings.totalContext;
    final threshold = settings.autoCompact ? settings.autoCompactPercent : null;
    final authors = contexts.keys.toList()..sort();
    return [
      PageSection(
        "participants",
        "",
        [
          CollectionController<String>(
            part("participants", "Participants", hint: UiHint.info),
            items: authors,
            removable: false,
            emptyLabel:
                "Nothing measured yet. The context is measured on each "
                "request; send a message to see it.",
            describe: (author) {
              final usage = contexts[author]!;
              final used = usage.total;
              final percent = (used * 100 / window).round();
              final name = nameOf(author);
              MeterSegment segment(String label, int tokens, MeterHue hue) =>
                  MeterSegment(label, _k(tokens), tokens / window, hue);
              return CollectionItem(
                author,
                subtitle: "$percent% · ${_k(used)} of ${_k(window)}",
                face: name == null
                    ? null
                    : AgentRowFace(project: project, name: name),
                editable: false,
                takesImage: false,
                meters: [
                  ItemMeter(
                    "",
                    fraction: (used / window).clamp(0, 1),
                    mark: threshold == null
                        ? null
                        : MeterMark(
                            threshold / 100,
                            "Auto-compact $threshold%",
                          ),
                    segments: [
                      segment(
                        "System prompt",
                        usage.share(usage.system),
                        MeterHue.grey,
                      ),
                      segment(
                        "Tool definitions",
                        usage.share(usage.tools),
                        MeterHue.orange,
                      ),
                      segment(
                        "Profile",
                        usage.share(usage.profile),
                        MeterHue.green,
                      ),
                      segment(
                        "Instructions",
                        usage.share(usage.instructions),
                        MeterHue.purple,
                      ),
                      segment("Chat", usage.share(usage.chat), MeterHue.blue),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
        detail:
            "The total is the provider's count where it reports one. The "
            "split is estimated at four characters a token.",
      ),
    ];
  }
}
