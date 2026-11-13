import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "package:path/path.dart" as p;

import "../../../app/pages/marketplace.dart";
import "../../../app/pages/text_file.dart";
import "../../../app/settings/spec.dart" show WidgetReader;
import "../../../app/transcript/activity.dart";
import "../../../domain/agent_browser.dart" show AgentBrowser, BrowserTab;
import "../../../providers.dart";
import "../../app_pages.dart";
import "../../widgets/dialogs.dart" show say;
import "../plan_page.dart" as plan_page;
import "../widgets/browser_strip.dart" show openBrowserTab;
import "../../app_chrome.dart";
import "../../widgets/page_bar.dart";
import "../../widgets/scrolling.dart" show ScrollFollow;
import "../widgets/code_block.dart" show codeBlockDecoration, codeBlockStyle;
import "../widgets/message_text.dart" show StreamingCaret;
import "../widgets/shell_run.dart" show ShellCommandText;
import "glyphs.dart";

export "../../../app/transcript/activity.dart" show LiveMessage, liveMessageOf;

/// Where a label's drawer reads its message from once it is open. The label
/// cannot be: it is rebuilt per delta, folded into a collapsed run when its
/// block closes, and gone when the list scrolls it away, all while the drawer
/// it opened is still up. Above each message on the chat page; absent, a
/// drawer shows what it was opened with and nothing more.
class ActivitySource extends InheritedWidget {
  const ActivitySource({super.key, required this.live, required super.child});

  final ProviderListenable<LiveMessage> live;

  static ProviderListenable<LiveMessage>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ActivitySource>()?.live;

  // Read once, at the tap that opens a drawer, so nothing depends on it.
  @override
  bool updateShouldNotify(ActivitySource oldWidget) => false;
}

/// The drawer behind a label as a sheet, opened at most of the screen. A
/// modal route, so the back key closes it; on a wide window as wide as a
/// reading column, not Material's 640. On the surface a dialog sits on, which
/// is what it is drawn after. Under the native shell a drawer is a page
/// instead; see [openActivityCard].
Future<T?> showActivityCard<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      constraints: const BoxConstraints(maxWidth: 960),
      builder: builder,
    );

/// A label's drawer, opened the way this window opens one: under the native
/// shell a page, not a sheet — the composer is the shell's, over the Flutter
/// view a sheet is drawn in, and a page is what it steps aside for, the
/// page's bar then the window's, with its back. [card] is told which.
Future<void> openActivityCard(
  BuildContext context,
  Widget Function(bool page) card,
) {
  final page = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appChromeProvider).drawersArePages;
  Widget build(BuildContext _) => card(page);
  if (page) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: build));
  }
  return showActivityCard<void>(context, build);
}

/// What a drawer draws, whoever is feeding it. Sections with nothing in them
/// are left out, so a tool that returned nothing does not show an empty
/// heading. [command] is set the way a `!` message is, under the title.
///
/// As a sheet it opens at most of the screen and grows to the whole of it: a
/// drawer sized to a one-line output was a strip at the bottom of the window,
/// and a fraction of the height left empty below a long one is a fraction of
/// the output not read. As a [page] — under the native shell, whose composer
/// a sheet would be drawn under — the title and actions are the page's bar,
/// which is the window's. While [live] it keeps to the end of what is
/// arriving until the reader scrolls back.
class ActivityCard extends StatefulWidget {
  const ActivityCard({
    super.key,
    required this.detail,
    this.below,
    this.page = false,
  });

  final ActivityDetail detail;

  /// Drawn under the sections: a sub-agent's transcript.
  final Widget? below;

  /// Drawn as a pushed page rather than a sheet.
  final bool page;

  @override
  State<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<ActivityCard> {
  final _scroll = ScrollController();
  late final _follow = ScrollFollow(_scroll);

  /// How much of the screen the sheet takes before what is in it asks for
  /// more.
  static const _openAt = 0.6;

  /// A page's column on a wide window: the sheet's width.
  static const _pageWidth = 960.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  ActivityDetail get _detail => widget.detail;

  @override
  Widget build(BuildContext context) {
    if (_detail.live) _follow.jumpIfFollowing();
    return widget.page ? _page(context) : _sheet(context);
  }

  Widget _page(BuildContext context) => Scaffold(
    appBar: PageBar(
      title: _detail.title,
      actions: [
        for (final action in _detail.actions)
          PageAction.text(
            label: action.label,
            onPressed: switch (action.run) {
              final run? => () => run(ContextHandOff(context)),
              null => null,
            },
          ),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _pageWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?_status(context, spinner: true),
              Expanded(child: _content(context, bottom: 24)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _sheet(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final header = Row(
      children: [
        if (_detail.glyph case final glyph?) ...[
          Icon(iconOf(glyph), size: 22, color: muted),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            _detail.title,
            style: theme.textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_detail.live)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _spinner(muted),
          ),
        for (final action in _detail.actions) _actionButton(action),
        IconButton(
          tooltip: "Close",
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight * _openAt),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              ?_status(context, spinner: false),
              const SizedBox(height: 8),
              Flexible(child: _content(context, bottom: 0)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(DetailAction action) {
    final run = action.run;
    final button = TextButton(
      onPressed: run == null ? null : () => run(ContextHandOff(context)),
      child: Text(action.label),
    );
    final why = action.why;
    return why == null ? button : Tooltip(message: why, child: button);
  }

  Widget _spinner(Color color) => SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2, color: color),
  );

  /// The line under the title: how the run stands, and on a page, whose bar
  /// has no room for it, the spinner saying it is still going.
  Widget? _status(BuildContext context, {required bool spinner}) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final status = _detail.status;
    final spin = spinner && _detail.live;
    if (status == null && !spin) return null;
    return Row(
      children: [
        if (spin) ...[_spinner(muted), const SizedBox(width: 8)],
        if (status != null)
          Flexible(
            child: Text(
              status.text,
              style: theme.textTheme.labelMedium?.copyWith(
                color: status.isError ? theme.colorScheme.error : muted,
              ),
            ),
          ),
      ],
    );
  }

  /// The command, the sections and what goes below them, scrolled.
  Widget _content(BuildContext context, {required double bottom}) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final extra = widget.below;
    final live = _detail.live;
    final mono = _detail.mono;
    final filled = _detail.filled.toList();

    Widget body(DetailSection section, {required bool last}) {
      final style = mono
          ? codeBlockStyle(
              theme,
            ).copyWith(color: section.isError ? theme.colorScheme.error : null)
          : theme.textTheme.bodyMedium?.copyWith(
              color: section.isError ? theme.colorScheme.error : null,
              height: 1.5,
            );
      final caret = live && last && !section.isError;
      final text = caret
          ? Text.rich(
              TextSpan(
                text: section.body,
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: StreamingCaret(
                      color: theme.colorScheme.primary,
                      height: style?.fontSize ?? 14,
                    ),
                  ),
                ],
              ),
              style: style,
            )
          // The newline output ends on would draw as a blank line under it.
          : Text(
              mono ? section.body!.trimRight() : section.body!,
              style: style,
            );
      if (!mono) return text;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: codeBlockDecoration(theme),
        child: text,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _follow.onNotification,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.only(right: 12, bottom: bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_detail.command case final command?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: ShellCommandText(command: command),
                    ),
                  for (final (i, section) in filled.indexed) ...[
                    if (section.label != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16, bottom: 8),
                        child: SelectionContainer.disabled(
                          child: Text(
                            section.label!,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: muted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    body(
                      section,
                      last: extra == null && i == filled.length - 1,
                    ),
                  ],
                ],
              ),
            ),
            ?extra,
          ],
        ),
      ),
    );
  }
}

/// The conversation's hand-off as the Flutter frontend makes it: a page
/// pushed over the [context] of what was tapped.
class ContextHandOff implements TranscriptHandOff {
  const ContextHandOff(this.context);

  final BuildContext context;

  ProviderContainer get _container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Future<void> openFile(String path) async => openAppPage(
    context,
    TextFileAppPage(path: path, name: p.basename(path), handsOff: false),
  );

  @override
  Future<void> openArtifact(
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) => _container
      .read(linkOpenerProvider)
      .openArtifact(
        context,
        chatId,
        artifactId,
        entryFile: entryFile,
        title: title,
      );

  @override
  Future<void> installSkill(String chatId, String installId) async =>
      openAppPage(
        context,
        SkillInstallAppPage(chatId: chatId, installId: installId),
      );

  @override
  Future<void> openPlan(String chatId) async =>
      plan_page.openPlan(context, chatId);

  @override
  Future<void> openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri != null) {
      await _container.read(linkOpenerProvider).open(context, uri);
    }
  }

  @override
  Future<void> openDetail(OpensDetail detail) => openActivityCard(
    context,
    (page) => _DetailCard(
      opens: detail.source == null
          ? OpensDetail(
              detail.activity,
              detail.run,
              source: ActivitySource.of(context),
            )
          : detail,
      page: page,
    ),
  );

  @override
  Future<void> openBrowser(AgentBrowser browser, BrowserTab tab) async =>
      openBrowserTab(context, browser, tab);

  @override
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) say(context, error);
    }
  }
}

class _DetailCard extends ConsumerWidget {
  const _DetailCard({required this.opens, required this.page});

  final OpensDetail opens;
  final bool page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = opens.detail(WidgetReader(ref));
    if (detail == null) return const SizedBox.shrink();
    final nested = detail.transcript;
    return ActivityCard(
      detail: detail,
      page: page,
      below: nested == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              // Its own source, so a label in the transcript opens a detail
              // that follows the sub-agent rather than the parent's reply.
              child: ActivitySource(
                live: nested.source,
                child: ref.watch(nestedTranscriptViewProvider)(nested),
              ),
            ),
    );
  }
}

/// Draws a transcript held inside a detail — a sub-agent's reply — the way
/// the conversation draws a message. A detail is inside a message and a
/// message is made of details' nodes, so the bubble is bound at the root
/// (`main`) rather than imported here.
final nestedTranscriptViewProvider =
    Provider<Widget Function(NestedTranscript)>(
      (ref) => throw UnimplementedError("bound where the app is assembled"),
    );
