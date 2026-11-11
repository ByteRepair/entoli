import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/reaction.dart";
import "../../app_chrome.dart";
import "../../widgets/action_icon.dart";
import "../../widgets/anchored_menu.dart";

/// The smiley under a message, and the strip of reactions it opens just above
/// itself, centred on it. What the message already has is shown chosen, and
/// picking it again takes it back. A frontend may draw the strip itself.
class ReactionButton extends ConsumerWidget {
  const ReactionButton({
    super.key,
    required this.onReact,
    this.chosen = const [],
  });

  /// A reaction picked: a new one, or one of [chosen] to take back.
  final ValueChanged<Reaction> onReact;

  /// The emoji already reacted with.
  final List<String> chosen;

  Future<void> _pick(BuildContext context, AppChrome chrome) async {
    final picked =
        await (chrome.pickReaction(context, chosen) ??
            showAnchoredPopup<Reaction>(
              context,
              (_) => _Strip(chosen: chosen),
            ));
    if (picked != null && context.mounted) onReact(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chrome = ref.watch(appChromeProvider);
    return ActionIcon(
      icon: Icons.add_reaction_outlined,
      tooltip: "React",
      onPressed: () => _pick(context, chrome),
    );
  }
}

/// The six reactions on a pill that hugs them, the chosen ones filled.
class _Strip extends StatelessWidget {
  const _Strip({required this.chosen});

  final List<String> chosen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      shape: const StadiumBorder(),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final reaction in Reaction.values)
              IconButton(
                tooltip: reaction.name,
                isSelected: chosen.contains(reaction.emoji),
                onPressed: () => Navigator.pop(context, reaction),
                style:
                    IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      fixedSize: const Size.square(40),
                      padding: EdgeInsets.zero,
                    ).copyWith(
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? scheme.secondaryContainer
                            : null,
                      ),
                    ),
                icon: Text(
                  reaction.emoji,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
