import "package:flutter/foundation.dart" show LicenseParagraph;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/local_model.dart" show isShortAskModel;
import "package:entoli_core/model/models.dart";
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/dialogs.dart";
import "package:entoli_core/view/widgets/page_bar.dart";
import "package:entoli_core/view/widgets/scrolling.dart";

import "../../app/first_run.dart";
import "../../app/settings/cli_account.dart" show connectCli;
import "../../data/builtin/llm/providers/presets.dart";
import "../../providers.dart";
import "../app_licence.dart";
import "../initial_setup_gate.dart";
import "../marketplace/marketplace_page.dart";
import "../widgets/app_mark.dart";
import "cli_sign_in_dialog.dart" show showCliSignIn;
import "llm_settings.dart" show newChatModelField, titleModelField;
import "provider_settings.dart" show editProvider;
import "settings_category.dart";

/// What a first launch shows over the app until the tour is finished: the
/// device's setup where a step of it is not done, then the tour.
Future<void> openFirstRun(BuildContext context, WidgetRef ref) async {
  if (ref.read(appSettingsProvider).licenceAccepted) return;
  final navigator = Navigator.of(context);
  if (setupNeeded(ref)) {
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => const SetupPage()),
    );
  }
  await navigator.push(
    MaterialPageRoute<void>(builder: (_) => const WelcomePage()),
  );
}

/// The welcome tour: what Entoli is, a model to answer with, what else
/// there is to set up, and the licence to agree to. On a first launch it is
/// the way into the app and cannot be left but by Done; replayed
/// ([welcomeRoute]) it is a page like any other.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, this.replay = false});

  final bool replay;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: replay,
    child: Scaffold(
      appBar: replay ? const PageBar(title: "Welcome") : null,
      body: const SafeArea(child: WelcomeTour()),
    ),
  );
}

/// The tour's slides in a [PageView], so a swipe does what the buttons do,
/// the buttons animating between them.
class WelcomeTour extends ConsumerStatefulWidget {
  const WelcomeTour({super.key});

  @override
  ConsumerState<WelcomeTour> createState() => _WelcomeTourState();
}

class _WelcomeTourState extends ConsumerState<WelcomeTour> {
  final _controller = PageController();
  int _page = 0;

  /// The last page's checkbox, which holds Done. Seeded from the stored tick.
  late final _accepted = ValueNotifier(
    ref.read(appSettingsProvider).licenceAccepted,
  );

  late final _pages = <Widget>[
    const _IntroPage(),
    const _ModelPage(),
    const _ExtrasPage(),
    _ResponsibilityPage(accepted: _accepted),
  ];

  /// Raised while Done writes the welcome chat, so a second tap is not a
  /// second chat.
  final _finishing = ValueNotifier(false);

  @override
  void dispose() {
    _controller.dispose();
    _accepted.dispose();
    _finishing.dispose();
    super.dispose();
  }

  void _go(int page) => _controller.animateToPage(
    page,
    duration: const Duration(milliseconds: 350),
    curve: Curves.easeInOutCubic,
  );

  Future<void> _done() {
    final navigator = Navigator.of(context);
    final app = ProviderScope.containerOf(context, listen: false);
    return whileBusy(context, _finishing, () async {
      await finishWelcomeTour(app);
      navigator.popUntil((route) => route.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    // The model page holds the tour until some model is reachable and new
    // chats have one to answer them; the swipe cannot go around the button.
    final reachable = ref.watch(
      availableModelsProvider.select((m) => _agentModels(m.value) > 0),
    );
    final chosen = ref.watch(
      appSettingsProvider.select((s) => s.defaultProviderId != null),
    );
    final gate = _pages[_page] is _ModelPage && !(reachable && chosen);
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            physics: gate ? const NeverScrollableScrollPhysics() : null,
            onPageChanged: (page) => setState(() => _page = page),
            itemCount: _pages.length,
            itemBuilder: (context, i) => _Fade(
              controller: _controller,
              index: i,
              current: _page,
              child: _pages[i],
            ),
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_accepted, _finishing]),
          builder: (context, _) => _TourBar(
            page: _page,
            pages: _pages.length,
            onPrevious: () => _go(_page - 1),
            onNext: () => _go(_page + 1),
            onDone: _done,
            nextEnabled: !gate,
            doneEnabled: _accepted.value && !_finishing.value,
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
      // No position before the first layout, nor while a page covers the
      // tour; a rebuild then must not dim the page.
      final position =
          controller.hasClients && controller.position.haveDimensions
          ? controller.page ?? current.toDouble()
          : current.toDouble();
      final distance = (position - index).abs().clamp(0.0, 1.0);
      return Opacity(opacity: 1 - distance * 0.8, child: child);
    },
  );
}

/// The dots, and under them Back on the left, Next or Done on the right.
class _TourBar extends StatelessWidget {
  const _TourBar({
    required this.page,
    required this.pages,
    required this.onPrevious,
    required this.onNext,
    required this.onDone,
    required this.nextEnabled,
    required this.doneEnabled,
  });

  final int page;
  final int pages;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function() onDone;
  final bool nextEnabled;
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

/// A slide's frame: centred, never wider than reads well, scrolling only
/// where a short window cannot hold it.
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

/// The icon in its tinted disc that heads a slide.
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

/// Icon, title, one line, and whatever the slide adds under them.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.icon,
    required this.title,
    required this.body,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String body;
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
        const SizedBox(height: 12),
        Text(
          body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        ...children,
      ],
    );
  }
}

/// The mark on a soft glow, the name, one line, and what the app is as a
/// short list rather than a slide each.
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

/// The models a chat can be answered by: a short-ask one, which an Apple
/// device lists before anything is set up, does not open the tour's gate.
int _agentModels(List<ModelOption>? models) => (models ?? const [])
    .where((m) => !isShortAskModel(m.providerId, m.modelId))
    .length;

/// Where the model runs: a service by the name its user knows it by,
/// connected with its recommended models, or the settings that hold the
/// rest. A service chosen here answers new chats at its own defaults, so
/// nothing is picked, unless models are reachable with nothing answering:
/// a setup from before, the one case that gets the pickers.
class _ModelPage extends ConsumerWidget {
  const _ModelPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = _agentModels(ref.watch(availableModelsProvider).value);
    final unanswered = ref.watch(
      appSettingsProvider.select((s) => s.defaultProviderId == null),
    );
    final scheme = Theme.of(context).colorScheme;
    return _Slide(
      icon: Icons.hub_outlined,
      title: "Connect a Model",
      body: "Choose a service. Entoli uses its recommended model.",
      children: [
        for (final service in welcomeProviders)
          if (service.supported)
            _SetupRow(
              icon: Icons.cloud_outlined,
              title: service.serviceName,
              detail: service.connectHint,
              open: (context) => _connect(context, ref, service),
            ),
        const _SetupRow.category(
          title: "Local Model",
          detail: "Download a model. No key, no network.",
          category: SettingsCategory.onDevice,
        ),
        const _SetupRow.category(
          title: "Advanced",
          detail: "Other providers, and endpoints by URL.",
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
                    if (unanswered) ...[
                      const SizedBox(height: 16),
                      newChatModelField,
                      titleModelField,
                    ],
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

  /// [service], connected as its kind is: a program installed and signed
  /// in, an API through its preset's dialog. Either answers new chats.
  static Future<void> _connect(
    BuildContext context,
    WidgetRef ref,
    OfferedByName service,
  ) => guarded(
    context,
    () => switch (service) {
      final CliProvider cli => connectCli(
        ref.read,
        cli,
        signIn: (config) => showCliSignIn(context, config),
      ),
      _ => editProvider(context, preset: service, adopt: true),
    },
  );
}

/// The optional extras, each a line and a way in.
class _ExtrasPage extends StatelessWidget {
  const _ExtrasPage();

  @override
  Widget build(BuildContext context) => _Slide(
    icon: Icons.tune,
    title: "More to Set Up",
    body: "Optional, and all here later.",
    children: [
      _SetupRow(
        icon: Icons.storefront_outlined,
        title: "Marketplace",
        detail: "Install skills and agents others have shared.",
        open: (context) async => openMarketplace(context),
      ),
      const _SetupRow.category(
        title: "Byte Repair",
        detail: "Code proved correct, not merely plausible.",
        category: SettingsCategory.byteRepair,
      ),
      const _SetupRow.category(
        title: "Triggers",
        detail: "A prompt sent on a schedule or when a file changes.",
        category: SettingsCategory.triggers,
      ),
      const _SetupRow.category(
        title: "Voice",
        detail: "Talk to the agent and hear it answer.",
        category: SettingsCategory.voice,
      ),
      const _SetupRow.category(
        title: "Image generation",
        detail: "Let the agent make images, shown in the chat.",
        category: SettingsCategory.images,
      ),
    ],
  );
}

/// The last page: the agent can be wrong, what it is let do is the user's
/// call, and the licence it comes under. The checkbox is at the end of the
/// licence, so reaching it means scrolling past it; ticked, it is pinned
/// under the licence. Done waits on it.
class _ResponsibilityPage extends ConsumerStatefulWidget {
  const _ResponsibilityPage({required this.accepted});

  final ValueNotifier<bool> accepted;

  @override
  ConsumerState<_ResponsibilityPage> createState() =>
      _ResponsibilityPageState();
}

class _ResponsibilityPageState extends ConsumerState<_ResponsibilityPage> {
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
                    "Check Its Work",
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

/// A way into something set up elsewhere: a settings category on its own,
/// a provider's dialog, or a page of its own. Not drawn where a category is
/// not offered here.
class _SetupRow extends ConsumerWidget {
  const _SetupRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.open,
  }) : category = null;

  const _SetupRow.category({
    required this.title,
    required this.detail,
    required SettingsCategory this.category,
  }) : icon = null,
       open = null;

  final IconData? icon;
  final String title;
  final String detail;
  final Future<void> Function(BuildContext context)? open;
  final SettingsCategory? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = this.category;
    if (category != null && !category.offered(ref)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon ?? category!.icon, color: scheme.primary),
        title: Text(title),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => category == null
            ? open!(context)
            : openSettings(context, category: category, focus: true),
      ),
    );
  }
}
