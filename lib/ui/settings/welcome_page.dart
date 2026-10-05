import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "../widgets/app_mark.dart";
import "llm_settings.dart";
import "memory_settings.dart";
import "settings_page.dart";

/// The welcome tour as the home content on first launch. It is the root route,
/// not a pushed one, so there is no back arrow; Done writes the flag and the
/// gate swaps the shell in.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text("Welcome"),
          automaticallyImplyLeading: false,
        ),
        body: const SafeArea(child: WelcomeTour()),
      );
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
    _WelcomeIntroPage(),
    _SetupModelPage(),
    _MemoryPage(),
    _ExtrasPage(),
    _ClosingPage(),
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

  Future<void> _done() async {
    await ref.read(appSettingsProvider.notifier).setWelcomeSeen(true);
  }

  @override
  Widget build(BuildContext context) {
    // The setup page asks for a model before the tour moves on: Next is dead
    // there until a provider is picked (its Default then answers), and the
    // swipe cannot go around the button.
    final chosen = ref.watch(
      appSettingsProvider.select((s) => s.defaultProviderId != null),
    );
    // Named off the page list, so reordering or inserting a page cannot move
    // the gate to the wrong one.
    final gate = _pageWidgets[_page] is _SetupModelPage && !chosen;
    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _controller,
            physics: gate ? const NeverScrollableScrollPhysics() : null,
            onPageChanged: (page) => setState(() => _page = page),
            children: _pageWidgets,
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

/// Previous and Done/Next at the bottom right, dots between.
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

  /// False is the setup page's gate, which holds the tour until a model is
  /// picked; every other page moves on freely.
  final bool nextEnabled;

  @override
  Widget build(BuildContext context) {
    final last = page == pages - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          const Spacer(),
          if (page > 0) ...[
            OutlinedButton(onPressed: onPrevious, child: const Text("Previous")),
            const SizedBox(width: 12),
          ],
          for (var i = 0; i < pages; i++)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == page
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          const SizedBox(width: 12),
          last
              ? FilledButton(onPressed: onDone, child: const Text("Done"))
              : FilledButton(
                  onPressed: nextEnabled ? onNext : null,
                  child: const Text("Next"),
                ),
        ],
      ),
    );
  }
}

/// Page 1: what this is over the hosted assistants.
class _WelcomeIntroPage extends StatelessWidget {
  const _WelcomeIntroPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        const Center(child: AppMark(size: 72)),
        const SizedBox(height: 16),
        Center(
          child: Text(
            "Welcome to Entoli",
            style: theme.textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          "Entoli is an assistant that runs on your machine. Where other "
          "assistants run on someone else's servers, here you bring your own "
          "model and everything happens locally. You use private LLMs, so "
          "your conversations stay private.",
        ),
        const SizedBox(height: 16),
        const _FeatureList([
          (Icons.key, "Choose a private LLM provider (OpenAI, Anthropic, "
              "OpenRouter or your own server), or host a model locally on "
              "your device."),
          (Icons.terminal, "The agent runs commands in a workspace on this "
              "machine, with your approval."),
          (Icons.psychology, "Skills, agents and per-project memories, all "
              "read from your own files."),
          (Icons.alarm, "Schedule the assistant to work at a time you pick, "
              "or let it wake itself to run a task with your approval."),
          (Icons.sync, "Pair your devices and carry a conversation between "
              "them."),
        ]),
      ],
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList(this.features);

  final List<(IconData, String)> features;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (icon, text) in features)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Page 2: where the model comes from, and which one answers a new chat.
class _SetupModelPage extends StatelessWidget {
  const _SetupModelPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text("Provider and Model Setup", style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          "Pick where the model runs: locally on this device, or at a "
          "provider over the network.",
        ),
        const SizedBox(height: 16),
        _SetupRow(
          title: "Use a local LLM",
          detail:
              "Download a model from the catalog and run it on this device. "
              "No key, no network.",
          category: SettingsCategory.onDevice,
        ),
        _SetupRow(
          title: "Pick a provider",
          detail:
              "Add an endpoint (Anthropic, OpenAI, OpenRouter and more) "
              "with your own API key.",
          category: SettingsCategory.providers,
        ),
        const Divider(height: 32),
        const DefaultsSection(),
      ],
    );
  }
}

/// One of page 2's two choices, which push the settings category they set up.
/// The icon is the category's own — one place an icon is named per category.
class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.title,
    required this.detail,
    required this.category,
  });

  final String title;
  final String detail;
  final SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: Icon(category.icon),
        title: Text(title),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                SettingsPage(initialCategory: category, focus: true),
          ),
        ),
      ),
    );
  }
}

/// Page 3: the Memory category's own sections, embedded as they are there.
class _MemoryPage extends StatelessWidget {
  const _MemoryPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text("Agent Memory", style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          "The agent can keep what it learns between chats, so it knows you "
          "a little better each time. Everything here can be changed later "
          "under Settings > Memory.",
        ),
        const SizedBox(height: 16),
        const AutoMemorySection(),
      ],
    );
  }
}

/// Page 4: the optional extras, each a line and a button into settings.
class _ExtrasPage extends StatelessWidget {
  const _ExtrasPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text("More to set up", style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          "Optional, and all reachable later from Settings. The button takes "
          "you to each one's page.",
        ),
        const SizedBox(height: 16),
        _SetupRow(
          title: "Byte Repair",
          detail:
              "Formally verified coding: the code it writes is checked "
              "against a mathematical model, so it is guaranteed correct "
              "rather than merely plausible. Ordinary assistants cannot do "
              "this.",
          category: SettingsCategory.byteRepair,
        ),
        _SetupRow(
          title: "Triggers",
          detail:
              "A prompt sent to a chat at a time you pick, a countdown, or a "
              "file changing. A schedule fires even when the app is closed.",
          category: SettingsCategory.triggers,
        ),
        _SetupRow(
          title: "Voice",
          detail:
              "Talk to the agent and be answered out loud, with a model that "
              "listens and one that speaks.",
          category: SettingsCategory.voice,
        ),
        _SetupRow(
          title: "Terminal",
          detail:
              "Where the agent's commands run: this machine, or a Linux "
              "downloaded and isolated from the rest of it. Environment "
              "variables for commands live under General.",
          category: SettingsCategory.terminal,
        ),
      ],
    );
  }
}

/// Page 5: what the app is for, and the one argument for it — an assistant
/// that answers to you rather than to someone else's service.
class _ClosingPage extends StatelessWidget {
  const _ClosingPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text("What you can do with Entoli",
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        const Text(
          "Summarize the day's news while you drink your coffee, draft the "
          "email you have been putting off, write and run code that compiles "
          "and tests clean, build a page and publish it as an artifact — "
          "anything you would ask of an assistant that works on your machine "
          "and answers to you.",
        ),
        const SizedBox(height: 16),
        const Text(
          "Because the model is yours, nothing you say leaves it without your "
          "say-so: your conversations are not training data, and no service "
          "stamps its own watermark into what Entoli writes for you. What "
          "your assistant produces is yours alone — the same words, with "
          "nobody else's fingerprint on them.",
        ),
        const SizedBox(height: 16),
        const Text(
          "Done below, and the app is yours.",
        ),
      ],
    );
  }
}
