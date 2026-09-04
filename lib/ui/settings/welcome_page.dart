import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "settings_page.dart";

/// The welcome tour: what the app is, then the settings a first run needs.
/// Four pages walked horizontally; reached first-launch from the app shell and
/// again from Settings, which is the first item in its list.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("Welcome")),
        body: SafeArea(child: WelcomeTour()),
      );
}

/// The tour itself, without the page around it — what the settings page embeds
/// where the route wraps it in a bar. Walking is a [PageView] (a swipe does
/// what the buttons do) and the buttons animate between pages.
class WelcomeTour extends ConsumerStatefulWidget {
  const WelcomeTour({super.key});

  @override
  ConsumerState<WelcomeTour> createState() => _WelcomeTourState();
}

class _WelcomeTourState extends ConsumerState<WelcomeTour> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = 4;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int page) => _controller.animateToPage(
        page.clamp(0, _pages - 1),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );

  Future<void> _done() async {
    await ref.read(appSettingsProvider.notifier).setWelcomeSeen(true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _controller,
            onPageChanged: (page) => setState(() => _page = page),
            children: const [
              _WelcomeIntroPage(),
              _SetupModelPage(),
              _MemoryPage(),
              _ExtrasPage(),
            ],
          ),
        ),
        _TourBar(
          page: _page,
          pages: _pages,
          onPrevious: () => _go(_page - 1),
          onNext: () => _go(_page + 1),
          onDone: _done,
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
  });

  final int page;
  final int pages;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function() onDone;

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
              : FilledButton(onPressed: onNext, child: const Text("Next")),
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
        Center(
          child: Text(
            "Welcome to Entoli",
            style: theme.textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          "Entoli is a coding agent that runs on your machine. Where a hosted "
          "assistant like ChatGPT or Claude answers through someone else's "
          "account and a shared interface, here you bring your own model and "
          "everything happens locally.",
        ),
        const SizedBox(height: 16),
        const _FeatureList([
          (Icons.key, "Your endpoints, your keys — OpenAI, Anthropic, "
              "OpenRouter or your own server, or a model running on the device."),
          (Icons.terminal, "The agent runs commands in a workspace on this "
              "machine, with your approval."),
          (Icons.psychology, "Skills, agents and per-project memories, read "
              "from your own files."),
          (Icons.alarm, "Reminders that run a prompt even when the app is "
              "closed, and voice mode for talking to it."),
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
        Text("A model to answer", style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          "Pick where the model runs: locally on this device, or at a "
          "provider over the network. Either way the model appears in the "
          "pickers below once it is set up.",
        ),
        const SizedBox(height: 16),
        _SetupRow(
          icon: Icons.memory,
          title: "Use a local LLM",
          detail:
              "Download a model from the catalog and run it on this device. "
              "No key, no network.",
          category: SettingsCategory.onDevice,
        ),
        _SetupRow(
          icon: Icons.cloud_outlined,
          title: "Pick a provider",
          detail:
              "Add an endpoint — Anthropic, OpenAI, OpenRouter and more — "
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
class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.category,
  });

  final IconData icon;
  final String title;
  final String detail;
  final SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SettingsPage(initialCategory: category),
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
      children: const [
        Text("What the agent carries between chats",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
        SizedBox(height: 8),
        Text(
          "The AGENTS.md instructions every turn is read from, and the "
          "memories the agent keeps for itself. Everything here can be "
          "changed later under Settings > Memory.",
        ),
        SizedBox(height: 16),
        InstructionsSection(),
        Divider(),
        AutoMemorySection(),
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
          icon: Icons.alarm,
          title: "Reminders",
          detail:
              "A prompt sent to a new chat at a time you pick, even when the "
              "app is closed. Android only.",
          category: SettingsCategory.reminders,
        ),
        _SetupRow(
          icon: Icons.graphic_eq,
          title: "Voice",
          detail:
              "Talk to the agent and be answered out loud, with a model that "
              "listens and one that speaks.",
          category: SettingsCategory.voice,
        ),
        _SetupRow(
          icon: Icons.terminal,
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
