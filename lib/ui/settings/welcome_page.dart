import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/chat_log.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../marketplace/marketplace_page.dart";
import "../sidebar/sidebar.dart";
import "../widgets/app_mark.dart";
import "llm_settings.dart";
import "settings_page.dart";

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

  static const _pageWidgets = [
    _IntroPage(),
    _Slide(
      icon: Icons.key,
      title: "Bring your own model",
      body: "Connect a provider you choose, or run a model right on this "
          "device. Your chats stay private.",
    ),
    _Slide(
      icon: Icons.terminal,
      title: "It works on your machine",
      body: "The agent runs commands in a workspace here, with your approval.",
    ),
    _Slide(
      icon: Icons.folder_outlined,
      title: "Made of your files",
      body: "Skills, agents and memories are plain files you own.",
    ),
    _Slide(
      icon: Icons.alarm,
      title: "Works on schedule",
      body: "Have it run a task at a time you pick, or when a file changes.",
    ),
    _Slide(
      icon: Icons.sync,
      title: "On all your devices",
      body: "Pair your devices and pick up a chat where you left it.",
    ),
    _ProviderPage(),
    _ModelPage(),
    _MemoryPage(),
    _ExtrasPage(),
    _IdeasPage(),
    _Slide(
      icon: Icons.lock_outline,
      title: "Yours alone",
      body: "Nothing leaves your model without your say-so, and no service "
          "stamps its watermark on what Entoli writes for you.",
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
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
        ...recordsOf([repo.composeUserPrompt("/entoli-welcome-party"), greeting]),
        ChatRecord.turnEnd(messageId: greeting.id, reason: TurnEnd.done),
      ]);
      ref.read(selectedProjectProvider.notifier).select(localProject(null));
      ref.read(selectedChatIdProvider.notifier).select(chat.state.id);
      ref.invalidate(chatListProvider);
    } catch (e) {
      logFailure("welcome", "could not start the welcome chat", e);
    }
    await ref.read(appSettingsProvider.notifier).setWelcomeSeen(true);
    // Replayed from settings, Done leaves them for the chat.
    navigator.popUntil((route) => route.isFirst);
  }

  static const _greeting = "Hello! Welcome to Entoli. I'm here to welcome you "
      "and help you customize the experience.\n\n"
      "By the way, if you ever want to talk to me again, just type "
      "/entoli-welcome-party and I'll respond.\n\n"
      "I have a few brief questions for you. What's your name?";

  @override
  Widget build(BuildContext context) {
    // The two setup pages hold the tour: the provider page until some model is
    // reachable, the model page until a default is picked. The swipe cannot go
    // around the button. Named off the page list, so reordering or inserting a
    // page cannot move a gate to the wrong one.
    final reachable = ref.watch(
        availableModelsProvider.select((m) => m.value?.isNotEmpty ?? false));
    final chosen = ref.watch(
      appSettingsProvider.select((s) => s.defaultProviderId != null),
    );
    final current = _pageWidgets[_page];
    final gate = (current is _ProviderPage && !reachable) ||
        (current is _ModelPage && !chosen);
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
              child: _pageWidgets[i],
            ),
          ),
        ),
        _TourBar(
          page: _page,
          pages: _pageWidgets.length,
          onPrevious: () => _go(_page - 1),
          onNext: () => _go(_page + 1),
          onDone: _done,
          nextEnabled: !gate,
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
    required this.child,
  });

  final PageController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        child: child,
        builder: (context, child) {
          // No position before the first layout.
          final position = controller.hasClients &&
                  controller.position.haveDimensions
              ? controller.page ?? 0
              : controller.initialPage.toDouble();
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
  });

  final int page;
  final int pages;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function() onDone;

  /// False is a setup page's gate; every other page moves on freely.
  final bool nextEnabled;

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
                  ? FilledButton(onPressed: onDone, child: const Text("Done"))
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
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (children.isNotEmpty) const SizedBox(height: 28),
        ...children,
      ],
    );
  }
}

/// The opening page: the mark on a soft glow, the name, one line.
class _IntroPage extends StatelessWidget {
  const _IntroPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Frame(
      children: [
        Center(
          child: Container(
            width: 200,
            height: 200,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                scheme.primaryContainer,
                scheme.primaryContainer.withValues(alpha: 0),
              ]),
            ),
            child: const AppMark(size: 104),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          "Welcome to Entoli",
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 12),
        Text(
          "An assistant that runs on your machine and answers to you.",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Where the model runs. Next waits here until some model is reachable.
class _ProviderPage extends ConsumerWidget {
  const _ProviderPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(availableModelsProvider).value?.length ?? 0;
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
              ? Row(
                  key: const ValueKey(true),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(count == 1 ? "1 model ready" : "$count models ready"),
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

/// Which model answers a new chat. Next waits here until one is picked.
class _ModelPage extends StatelessWidget {
  const _ModelPage();

  @override
  Widget build(BuildContext context) => const _Slide(
        icon: Icons.auto_awesome_outlined,
        title: "Pick a model",
        body: "The one that answers a new chat, and the one that names it.",
        children: [DefaultsSection()],
      );
}

/// One switch: the Memory category's "Keep memories", every other memory
/// setting left at its default.
class _MemoryPage extends ConsumerWidget {
  const _MemoryPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(appSettingsProvider.select((s) => s.autoMemory));
    return _Slide(
      icon: Icons.psychology,
      title: "Remember things",
      body: "The agent can keep what it learns between chats.",
      children: [
        Card(
          child: SwitchListTile(
            title: const Text("Enable memories"),
            value: on,
            onChanged: (value) =>
                ref.read(appSettingsProvider.notifier).setAutoMemory(value),
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
            open: (_) => const MarketplacePage(),
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
          _SetupRow.category(
            title: "Terminal",
            detail: "Run commands here, or in an isolated Linux.",
            category: SettingsCategory.terminal,
          ),
        ],
      );
}

/// A few things to ask for, as chips rather than a paragraph.
class _IdeasPage extends StatelessWidget {
  const _IdeasPage();

  static const _ideas = [
    (Icons.newspaper, "Summarise the news"),
    (Icons.mail_outline, "Draft that email"),
    (Icons.code, "Write and test code"),
    (Icons.web, "Publish a page"),
  ];

  @override
  Widget build(BuildContext context) => _Slide(
        icon: Icons.lightbulb_outline,
        title: "Ask it anything",
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (icon, label) in _ideas)
                Chip(avatar: Icon(icon, size: 18), label: Text(label)),
            ],
          ),
        ],
      );
}

/// A way into something set up elsewhere: a settings category pushed on its
/// own, or a page of its own.
class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.open,
  });

  /// The icon is the category's own — one place an icon is named per category.
  _SetupRow.category({
    required String title,
    required String detail,
    required SettingsCategory category,
  }) : this(
          icon: category.icon,
          title: title,
          detail: detail,
          open: (_) => SettingsPage(initialCategory: category, focus: true),
        );

  final IconData icon;
  final String title;
  final String detail;
  final WidgetBuilder open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(title),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: open)),
      ),
    );
  }
}
