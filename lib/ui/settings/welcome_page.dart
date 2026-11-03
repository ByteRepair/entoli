import "dart:async";

import "package:flutter/foundation.dart" show LicenseParagraph;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/chat_log.dart";
import "../../domain/local_model.dart" show isTitleOnlyModel;
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../marketplace/marketplace_page.dart";
import "../selection.dart";
import "../app_licence.dart";
import "../widgets/app_mark.dart";
import "../widgets/dialogs.dart";
import "../widgets/scrolling.dart";
import "llm_settings.dart";
import "settings_category.dart";

/// The welcome tour as the home content on first launch. It is the root route,
/// not a pushed one, so there is no back arrow; Done writes the flag and the
/// gate swaps the shell in.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SafeArea(child: WelcomeTour()));
}

/// The tour itself, without the page around it — what the settings page embeds
/// where the route wraps it in a bar. Walking is a [PageView] (a swipe does
/// what the buttons do) and the buttons animate between pages. Done writes the
/// flag; the host reacts to it.
class WelcomeTour extends ConsumerStatefulWidget {
  const WelcomeTour({super.key});

  @override
  ConsumerState<WelcomeTour> createState() => _WelcomeTourState();
}

class _WelcomeTourState extends ConsumerState<WelcomeTour> {
  final _controller = PageController();
  int _page = 0;

  /// The last page's checkbox, which holds Done. Seeded from the stored tick,
  /// which Done writes.
  late final _accepted = ValueNotifier(
    ref.read(appSettingsProvider).licenceAccepted,
  );

  late final _pageWidgets = <Widget>[
    _IntroPage(),
    _ModelPage(),
    _ExtrasPage(),
    _ResponsibilityPage(accepted: _accepted),
  ];

  @override
  void dispose() {
    _controller.dispose();
    _accepted.dispose();
    super.dispose();
  }

  void _go(int page) => _controller.animateToPage(
    page,
    duration: const Duration(milliseconds: 350),
    curve: Curves.easeInOutCubic,
  );

  /// Opens the welcome chat: the `/entoli-welcome-party` skill as its first
  /// message, so the skill's instructions reach every turn the way any skill
  /// message's do, and its greeting under that. Always the default project,
  /// whose library holds the skill.
  Future<void> _done() async {
    final navigator = Navigator.of(context);
    final repo = ref.read(chatRepositoryProvider);
    try {
      final chat = await repo.createChat(title: "Welcome to Entoli");
      final greeting = Message(
        id: const Uuid().v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        parts: const [MessagePart.text(text: _greeting)],
      );
      await repo.append(chat.state.id, [
        ...recordsOf([
          repo.composeUserPrompt("/entoli-welcome-party"),
          greeting,
        ]),
        ChatRecord.turnEnd(messageId: greeting.id, reason: TurnEnd.done),
      ]);
      ref.read(selectedProjectProvider.notifier).select(localProject(null));
      ref.read(selectedChatIdProvider.notifier).select(chat.state.id);
      ref.invalidate(chatListProvider);
    } catch (e) {
      logFailure("welcome", "could not start the welcome chat", e);
    }
    await ref.read(appSettingsProvider.notifier).setLicenceAccepted(true);
    // Replayed from settings, Done leaves them for the chat.
    navigator.popUntil((route) => route.isFirst);
  }

  static const _greeting =
      "Hello! Welcome to Entoli. I'm here to welcome you "
      "and help you customize the experience.\n\n"
      "By the way, if you ever want to talk to me again, just type "
      "/entoli-welcome-party and I'll respond.\n\n"
      "I have a few brief questions for you. What's your name?";

  @override
  Widget build(BuildContext context) {
    // The model page holds the tour until some model is reachable and a
    // default is picked. The swipe cannot go around the button. Named off the
    // page list, so reordering or inserting a page cannot move the gate.
    final reachable = ref.watch(
      availableModelsProvider.select((m) => _agentModels(m.value) > 0),
    );
    final chosen = ref.watch(
      appSettingsProvider.select((s) => s.defaultProviderId != null),
    );
    final gate = _pageWidgets[_page] is _ModelPage && !(reachable && chosen);
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            physics: gate ? const NeverScrollableScrollPhysics() : null,
            onPageChanged: (page) => setState(() => _page = page),
            itemCount: _pageWidgets.length,
            itemBuilder: (context, i) => _Fade(
              controller: _controller,
              index: i,
              current: _page,
              child: _pageWidgets[i],
            ),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: _accepted,
          builder: (context, accepted, _) => _TourBar(
            page: _page,
            pages: _pageWidgets.length,
            onPrevious: () => _go(_page - 1),
            onNext: () => _go(_page + 1),
            onDone: _done,
            nextEnabled: !gate,
            doneEnabled: accepted,
          ),
        ),
      ],
    );
  }
}

/// Fades a page out as it slides away, so only one slide reads at a time.
class _Fade extends StatelessWidget {
  const _Fade({
    required this.controller,
    required this.index,
    required this.current,
    required this.child,
  });

  final PageController controller;
  final int index;

  /// The page the tour is on, for when the controller has no position.
  final int current;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: child,
    builder: (context, child) {
      // No position before the first layout, nor while settings covers
      // the tour; a rebuild then (a provider added) must not dim the page.
      final position =
          controller.hasClients && controller.position.haveDimensions
          ? controller.page ?? current.toDouble()
          : current.toDouble();
      final distance = (position - index).abs().clamp(0.0, 1.0);
      return Opacity(opacity: 1 - distance * 0.8, child: child);
    },
  );
}

/// Back on the left, Next or Done on the right, the progress above them.
class _TourBar extends StatelessWidget {
  const _TourBar({
    required this.page,
    required this.pages,
    required this.onPrevious,
    required this.onNext,
    required this.onDone,
    this.nextEnabled = true,
    this.doneEnabled = true,
  });

  final int page;
  final int pages;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function() onDone;

  /// False is a setup page's gate; every other page moves on freely.
  final bool nextEnabled;

  /// False until the last page's checkbox is ticked.
  final bool doneEnabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = page == pages - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < pages; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  width: i == page ? 20 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i == page ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (page > 0)
                TextButton(onPressed: onPrevious, child: const Text("Back")),
              const Spacer(),
              last
                  ? FilledButton(
                      onPressed: doneEnabled ? onDone : null,
                      child: const Text("Done"),
                    )
                  : FilledButton(
                      onPressed: nextEnabled ? onNext : null,
                      child: const Text("Next"),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A page's frame: centred in the space it has, never wider than reads well,
/// and scrolling only when a short window cannot hold it.
class _Frame extends StatelessWidget {
  const _Frame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The icon in its tinted disc that heads every slide.
class _Badge extends StatelessWidget {
  const _Badge(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primaryContainer,
        ),
        child: Icon(icon, size: 40, color: scheme.onPrimaryContainer),
      ),
    );
  }
}

/// Icon, title, one line, and whatever the page adds under them.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.icon,
    required this.title,
    this.body,
    this.children = const [],
  });

  final IconData icon;
  final String title;
  final String? body;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Frame(
      children: [
        _Badge(icon),
        const SizedBox(height: 28),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium,
        ),
        if (body != null) ...[
          const SizedBox(height: 12),
          Text(
            body!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (children.isNotEmpty) const SizedBox(height: 28),
        ...children,
      ],
    );
  }
}

/// The opening page: the mark on a soft glow, the name, one line, and what the
/// app is as a short list rather than a slide each.
class _IntroPage extends StatelessWidget {
  const _IntroPage();

  static const _features = [
    (
      Icons.key,
      "Bring your own model",
      "A provider you choose, or one running right on this device.",
    ),
    (
      Icons.terminal,
      "It works on your machine",
      "Commands run in a workspace here, with your approval.",
    ),
    (
      Icons.folder_outlined,
      "Made of your files",
      "Skills, agents and memories are plain files you own.",
    ),
    (
      Icons.alarm,
      "Works on schedule",
      "A task at a time you pick, or when a file changes.",
    ),
    (
      Icons.sync,
      "On all your devices",
      "Pair them and pick up a chat where you left it.",
    ),
    (
      Icons.lock_outline,
      "Yours alone",
      "Nothing leaves without your say-so, and nothing is watermarked.",
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Frame(
      children: [
        Center(
          child: Container(
            width: 144,
            height: 144,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  scheme.primaryContainer,
                  scheme.primaryContainer.withValues(alpha: 0),
                ],
              ),
            ),
            child: const AppMark(size: 76),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          "Welcome to Entoli",
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 12),
        Text(
          "An assistant that runs on your machine and answers to you.",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        for (final (icon, title, detail) in _features)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: scheme.primary),
            title: Text(title),
            subtitle: Text(detail),
          ),
      ],
    );
  }
}

/// The models a chat can be answered by: a title-only one, which an iOS
/// device lists before anything is set up, does not open the tour's gate.
int _agentModels(List<ModelOption>? models) => (models ?? const [])
    .where((m) => !isTitleOnlyModel(m.providerId, m.modelId))
    .length;

/// Where the model runs, and once one is reachable, which answers a new chat.
/// Next waits here until some model is reachable and a default is picked.
class _ModelPage extends ConsumerWidget {
  const _ModelPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = _agentModels(ref.watch(availableModelsProvider).value);
    final scheme = Theme.of(context).colorScheme;
    return _Slide(
      icon: Icons.hub_outlined,
      title: "Connect a model",
      body: "Run one on this device, or reach one over the network.",
      children: [
        _SetupRow.category(
          title: "On this device",
          detail: "Download a model. No key, no network.",
          category: SettingsCategory.onDevice,
        ),
        _SetupRow.category(
          title: "A provider",
          detail: "Anthropic, OpenAI, OpenRouter and more, with your key.",
          category: SettingsCategory.providers,
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: count > 0
              ? Column(
                  key: const ValueKey(true),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          count == 1 ? "1 model ready" : "$count models ready",
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const DefaultsSection(),
                  ],
                )
              : Text(
                  key: const ValueKey(false),
                  "Set one up to continue.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
        ),
      ],
    );
  }
}

/// The optional extras, each a line and a way in.
class _ExtrasPage extends StatelessWidget {
  const _ExtrasPage();

  @override
  Widget build(BuildContext context) => _Slide(
    icon: Icons.tune,
    title: "More to set up",
    body: "Optional, and all here later.",
    children: [
      _SetupRow(
        icon: Icons.storefront_outlined,
        title: "Marketplace",
        detail: "Install skills and agents others have shared.",
        open: openMarketplace,
      ),
      _SetupRow.category(
        title: "Byte Repair",
        detail: "Code proved correct, not merely plausible.",
        category: SettingsCategory.byteRepair,
      ),
      _SetupRow.category(
        title: "Triggers",
        detail: "A prompt sent on a schedule or when a file changes.",
        category: SettingsCategory.triggers,
      ),
      _SetupRow.category(
        title: "Voice",
        detail: "Talk to the agent and hear it answer.",
        category: SettingsCategory.voice,
      ),
      _SetupRow.category(
        title: "Image generation",
        detail: "Let the agent make images, shown in the chat.",
        category: SettingsCategory.images,
      ),
    ],
  );
}

/// The last page: the agent can be wrong, what it is let do is the user's
/// call, and the licence it comes under. The checkbox is at the end of the
/// licence, so reaching it means scrolling past it; ticked, it is pinned under
/// the licence. Done waits on it.
class _ResponsibilityPage extends ConsumerStatefulWidget {
  const _ResponsibilityPage({required this.accepted});

  final ValueNotifier<bool> accepted;

  @override
  ConsumerState<_ResponsibilityPage> createState() =>
      _ResponsibilityPageState();
}

class _ResponsibilityPageState extends ConsumerState<_ResponsibilityPage> {
  /// Unwrapped the way the licence page unwraps every entry, indents kept.
  static final _licence = appLicence.paragraphs.toList();

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Unticking a stored tick takes the tour back with it and builds the app
  /// again, which stops what it was running and opens it on the tour.
  Future<void> _set(bool accepted) async {
    if (accepted || !ref.read(appSettingsProvider).licenceAccepted) {
      widget.accepted.value = accepted;
      return;
    }
    final restart = ref.read(appRestartProvider);
    final ok = await confirm(
      context,
      title: "Untick the licence?",
      message: "By unticking, the app will restart.",
      confirmLabel: "Restart",
      destructive: true,
    );
    if (!ok) return;
    await ref.read(appSettingsProvider.notifier).setLicenceAccepted(false);
    await restart.restart();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return ValueListenableBuilder(
      valueListenable: widget.accepted,
      builder: (context, accepted, _) {
        final checkbox = CheckboxListTile(
          title: const Text(
            "I have read the licence, and I take full responsibility for "
            "how I use Entoli and what I let it do.",
          ),
          value: accepted,
          onChanged: (v) => _set(v ?? false),
        );
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    "Check its work",
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 16),
                  // Only the title and the box are outside the scroll, so a
                  // short window still has room for the licence.
                  Expanded(
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: Scrollbar(
                        controller: _scroll,
                        // Not a ListView: a lazy list guesses its length from
                        // what it has built, and the thumb jumps as the guess
                        // changes.
                        child: SingleChildScrollView(
                          key: const ValueKey("licence"),
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                "AI can make mistakes. Review what it does, "
                                "and the commands you approve, before you "
                                "rely on them. Entoli comes under the "
                                "licence below, with no warranty.",
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 16),
                              for (final p in _licence)
                                Padding(
                                  padding: EdgeInsets.only(
                                    left: p.indent > 0 ? 16.0 * p.indent : 0,
                                    bottom: 8,
                                  ),
                                  child: Text(
                                    p.text,
                                    textAlign:
                                        p.indent ==
                                            LicenseParagraph.centeredIndent
                                        ? TextAlign.center
                                        : TextAlign.start,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              if (!accepted) checkbox,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (accepted)
                    Card(child: checkbox)
                  else
                    _ScrollHint(scroll: _scroll),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Says the checkbox is further down, until the licence is scrolled to it.
class _ScrollHint extends StatelessWidget {
  const _ScrollHint({required this.scroll});

  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListenableBuilder(
      listenable: scroll,
      builder: (context, _) {
        final atEnd =
            scroll.hasClients &&
            scroll.position.hasContentDimensions &&
            scroll.position.nearBottom(24);
        return AnimatedOpacity(
          opacity: atEnd ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.keyboard_double_arrow_down, size: 18, color: muted),
                const SizedBox(width: 6),
                Text(
                  "Scroll to the end to agree",
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A way into something set up elsewhere: a settings category pushed on its
/// own, or a page of its own.
class _SetupRow extends ConsumerWidget {
  const _SetupRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.open,
  }) : category = null;

  /// The icon is the category's own — one place an icon is named per category.
  _SetupRow.category({
    required this.title,
    required this.detail,
    required SettingsCategory this.category,
  }) : icon = category.icon,
       open = ((context) =>
           openSettings(context, category: category, focus: true));

  final IconData icon;
  final String title;
  final String detail;
  final void Function(BuildContext context) open;

  /// Where the row leads, if a category: not drawn where it is not offered.
  final SettingsCategory? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (category?.offered(ref) == false) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(title),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => open(context),
      ),
    );
  }
}
