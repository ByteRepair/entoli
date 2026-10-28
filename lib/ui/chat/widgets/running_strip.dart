import "dart:async";

import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../../domain/agent_backend.dart" show SubAgentStartEvent;
import "../../../domain/models.dart" show JobEnd;
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../../domain/shell_job.dart";
import "../../../domain/tool_arg.dart";
import "../../../providers.dart";
import "../../fonts.dart";
import "../../widgets/dialogs.dart";
import "browser_strip.dart" show BrowserPill;
import "activity_label.dart"
    show
        ActivityCard,
        ActivitySource,
        jobStatus,
        liveMessageOf,
        plural,
        showActivityCard,
        showTaskSheet,
        toolCallIn;

/// What the chat has running beside the reply, as one row of pills that
/// scrolls sideways: the browser's tab first, then the background jobs and the
/// sub-agents, each a group that opens to a pill apiece. A sub-agent's pill
/// opens the drawer its label in the reply opens; a job's, the command and the
/// end of its log. Jobs are not turn-scoped, since a job outlives the turn
/// that started it, and not on a mirrored chat, whose jobs are the other
/// device's.
class RunningStrip extends ConsumerStatefulWidget {
  const RunningStrip({super.key, required this.view, this.source});

  final ChatViewState view;

  /// What a sub-agent's drawer follows. Null, it shows what it opened with.
  final ProviderListenable<ChatViewState>? source;

  @override
  ConsumerState<RunningStrip> createState() => _RunningStripState();
}

class _RunningStripState extends ConsumerState<RunningStrip> {
  final _scroll = ScrollController();
  bool _jobsOpen = false;
  bool _agentsOpen = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A mouse wheel turned over the row scrolls it sideways, with no Shift:
  /// the row is the one thing under the pointer that scrolls.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta;
      final position = _scroll.position;
      position.jumpTo((position.pixels + delta.dy + delta.dx)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final chatId = view.chat?.state.id;
    final agents = [
      for (final MapEntry(key: replyId, value: list)
          in view.runningSubAgents.entries)
        for (final agent in list) (replyId: replyId, agent: agent),
    ];
    final jobs = chatId == null || ref.watch(isMirroredChatProvider(chatId))
        ? null
        : ref.watch(agentBackendProvider).jobsOf(chatId);
    Widget row(List<ShellJob> running) {
      return Listener(
        onPointerSignal: _wheel,
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (chatId != null) BrowserPill(chatId: chatId),
              if (running.isNotEmpty)
                _Group(
                  label: "${plural(running.length, "background task")} running",
                  open: _jobsOpen,
                  onToggle: () => setState(() => _jobsOpen = !_jobsOpen),
                  children: [
                    for (final job in running)
                      _Pill(
                        label: firstLine(job.command),
                        mono: true,
                        tooltip: "Background job ${job.id}",
                        onPressed: () => showActivityCard<void>(
                            context, (_) => JobSheet(jobs: jobs!, job: job)),
                      ),
                  ],
                ),
              if (chatId != null && agents.isNotEmpty)
                _Group(
                  label: "${plural(agents.length, "sub-agent")} running",
                  open: _agentsOpen,
                  onToggle: () => setState(() => _agentsOpen = !_agentsOpen),
                  children: [
                    for (final (:replyId, :agent) in agents)
                      _SubAgentPill(
                        chatId: chatId,
                        replyId: replyId,
                        agent: agent,
                        view: view,
                        source: widget.source,
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    }

    if (jobs == null) return row(const []);
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: jobs.jobs,
      builder: (context, list, _) => row(list),
    );
  }
}

/// "3 sub-agents running", which a tap opens to a pill per sub-agent and
/// closes again. Open, the pills sit inside it, on its own surface.
class _Group extends StatelessWidget {
  const _Group({
    required this.label,
    required this.open,
    required this.onToggle,
    required this.children,
  });

  final String label;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  static const _duration = Duration(milliseconds: 260);
  static const _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = InkWell(
      customBorder: const StadiumBorder(),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: scheme.primary),
            ),
            const SizedBox(width: 8),
            Text(label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w500)),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: _duration,
              curve: _curve,
              child: Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: _duration,
          curve: _curve,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              if (open)
                for (final child in children)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: _duration,
                      curve: _curve,
                      builder: (context, t, child) => Opacity(
                        opacity: t,
                        child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
                      ),
                      child: child,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubAgentPill extends StatelessWidget {
  const _SubAgentPill({
    required this.chatId,
    required this.replyId,
    required this.agent,
    required this.view,
    required this.source,
  });

  final String chatId;
  final String replyId;
  final SubAgentStartEvent agent;
  final ChatViewState view;
  final ProviderListenable<ChatViewState>? source;

  @override
  Widget build(BuildContext context) {
    final pill = Builder(
      builder: (context) => _Pill(
        label: "@${agent.agent}",
        tooltip: "Sub-agent @${agent.agent}",
        onPressed: () {
          final reply =
              view.chat?.messages.where((m) => m.id == replyId).firstOrNull;
          final call = toolCallIn(reply, agent.id);
          // The event's prompt is cut for the pill; the call has all of it.
          final prompt = stringArg(call?.argumentsJson, "prompt") ?? agent.prompt;
          showTaskSheet(context,
              chatId: chatId,
              callId: agent.id,
              agent: agent.agent,
              prompt: prompt);
        },
      ),
    );
    final follow = source;
    if (follow == null) return pill;
    return ActivitySource(
      live: follow.select((v) => liveMessageOf(v, replyId)),
      child: pill,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.mono = false,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = theme.colorScheme.onPrimaryContainer;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ActionChip(
        avatar: SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: colour),
        ),
        label: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: mono
              ? TextStyle(fontFamily: monoFamily, fontSize: 12, color: colour)
              : theme.textTheme.labelMedium
                  ?.copyWith(color: colour, fontWeight: FontWeight.w500),
        ),
        backgroundColor: theme.colorScheme.primaryContainer,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: onPressed,
      ),
    );
  }
}

/// One job: the command, whether it still runs, and the end of its log as it
/// grows. The drawer a tool run opens, so a job reads as the command it is.
class JobSheet extends StatefulWidget {
  const JobSheet({super.key, required this.jobs, required this.job});

  final ChatShellJobs jobs;
  final ShellJob job;

  @override
  State<JobSheet> createState() => _JobSheetState();
}

class _JobSheetState extends State<JobSheet> {
  // Once, not per build: a new stream per rebuild would restart the tail.
  late final Stream<String> _log = widget.jobs.log(widget.job);
  JobEnd? _end;
  late final StreamSubscription<void> _ended;

  @override
  void initState() {
    super.initState();
    _ended = widget.jobs.ended
        .where((e) => e.callId == widget.job.callId)
        .listen((e) => setState(() => _end = e.end));
  }

  @override
  void dispose() {
    unawaited(_ended.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: widget.jobs.jobs,
      builder: (context, list, _) {
        // An ended job leaves the list; the sheet keeps its last log.
        final running = list.any((j) => j.id == job.id);
        return StreamBuilder<String>(
          stream: _log,
          builder: (context, log) {
            final text = log.data ?? "";
            return ActivityCard(
              title: "Background job ${job.id}",
              icon: Icons.terminal,
              command: job.command,
              status: running
                  ? (
                      text: "Running${job.pid == null ? "" : " · pid ${job.pid}"}",
                      isError: false,
                    )
                  : _end == null
                      ? (text: "Ended", isError: false)
                      : jobStatus(_end),
              actions: [
                if (running)
                  TextButton(
                    onPressed: () =>
                        catchAndSay(context, () => widget.jobs.stop(job.id)),
                    child: const Text("Stop"),
                  ),
              ],
              mono: true,
              live: running,
              sections: [
                (
                  label: "Output",
                  body: text.isEmpty ? "(nothing printed yet)" : text,
                  isError: false,
                ),
              ],
            );
          },
        );
      },
    );
  }
}
