import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../../domain/models.dart";
import "card.dart";
import "label.dart";

/// Which kind of activity each part of a message is drawn as. The reply asks
/// it and knows none of the kinds: a reply is made of activities, and one of
/// them, a sub-agent's, draws a reply of its own in its drawer — a composite,
/// which only stays acyclic with the reply depending on this rather than on
/// the kinds. `ChatActivities` answers, bound once where the app is assembled.
abstract interface class ActivityCatalog {
  /// The kind [part] is drawn as, or null for a part that is not one — text,
  /// an error, a file, a command the user ran.
  Activity? of(MessagePart part);
}

/// The [ActivityCatalog] the app draws replies with; `main` and the test
/// harness bind it.
final activityCatalogProvider = Provider<ActivityCatalog>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);

/// Anything drawn among the activities above a reply: a tool run, a thinking
/// block, an instruction file read, a permission answered, an artifact. One
/// class per kind, holding no state; what one of them is drawn from is a
/// [Run]. The reply asks the [ActivityCatalog] which kind a part is and draws
/// what [build] returns.
abstract class Activity {
  const Activity();

  /// Stands on a row of its own rather than joining the run of activities
  /// that collapses behind one toggle: what the turn stopped to show.
  bool important(Run run) => false;

  /// What the reply draws for [run].
  Widget build(Run run);
}

/// An activity drawn as a one-line label that opens a drawer, both from
/// [view]. A kind whose label is content — a diff, a question, the plan —
/// overrides [build] and opens the same drawer with [open].
abstract class LabelledActivity extends Activity {
  const LabelledActivity();

  /// [run] as it stands now: the label's line, and the drawer behind it.
  RunView view(WidgetRef ref, Run run);

  /// [run] as [now], the message it is in, holds it, for a drawer left open
  /// while its turn runs; null where the message does not hold it. A tool run
  /// is found by its call.
  Run? follow(Run run, LiveMessage now) {
    final callId = run.callId;
    final found = callId == null ? null : _runIn(now.message, callId);
    if (found == null) return null;
    final going = now.running && found.result == null;
    return Run(
      chatId: run.chatId,
      callId: callId,
      call: found.call ?? run.call,
      result: found.result,
      printing: going ? now.shellOutput : null,
      going: going,
    );
  }

  @override
  Widget build(Run run) => RunLabel(activity: this, run: run);

  /// Opens [run]'s drawer. It follows the run's message through [source], or
  /// the [ActivitySource] above [context]; with neither it shows the run as
  /// it was opened.
  Future<void> open(
    BuildContext context,
    Run run, {
    ProviderListenable<LiveMessage>? source,
  }) {
    final from = source ?? ActivitySource.of(context);
    return showActivityCard<void>(
      context,
      (_) => _RunCard(activity: this, run: run, source: from),
    );
  }
}

/// One activity as it is drawn: the call and its result for a tool run, the
/// part otherwise, and whether it is still going where it is drawn.
class Run {
  const Run({
    required this.chatId,
    this.callId,
    this.call,
    this.result,
    this.part,
    this.at,
    this.printing,
    this.going = false,
  });

  final String chatId;

  /// The call a tool run answers to; null for an activity that is not one.
  final String? callId;

  /// Null where the call is not to hand: a result whose call is gone, or a
  /// running pill opening a drawer before the call is followed.
  final ToolCall? call;

  /// Null while the tool is still running.
  final ToolResult? result;

  /// What a run that is not a call is drawn from: a thinking block, an
  /// instruction read, a permission, an artifact.
  final MessagePart? part;

  /// Where [part] sits in its message, which is what an open drawer finds it
  /// by as it grows.
  final int? at;

  /// What a running command has printed so far, standing in for the output
  /// it has not returned yet.
  final String? printing;

  /// Still going where it is drawn: a tool the turn is running, the label of
  /// a waiting turn that has already said something — the spinner below the
  /// message handles the no-text-yet case — or a thinking block being
  /// written; in a drawer, one following a turn still running it.
  final bool going;

  /// As a drawer with nothing to follow shows it: done arriving.
  Run get settled => Run(
    chatId: chatId,
    callId: callId,
    call: call,
    result: result,
    part: part,
    at: at,
  );
}

/// An activity on screen: the one-line label in the reply, and the drawer
/// behind it, as the run stands now.
class RunView {
  const RunView({
    required this.icon,
    required this.label,
    required this.drawer,
    this.isError = false,
    this.markError = true,
    this.busy = false,
  });

  /// The kind's; a failed run's label says so with its own.
  final IconData icon;
  final String label;
  final bool isError;

  /// An [isError] label shows the error mark in place of [icon]; false where
  /// [icon] already says how it went, as a permission's does.
  final bool markError;

  /// The label spins rather than showing [icon].
  final bool busy;

  /// What the drawer shows, built only for a drawer and watching through the
  /// drawer's ref: a label is rebuilt for every activity in every visible
  /// reply, and what only the drawer reads — a log, a transcript — is not
  /// for it.
  final RunDrawer Function(WidgetRef ref) drawer;
}

/// What a run's drawer draws; see [ActivityCard].
class RunDrawer {
  const RunDrawer({
    required this.title,
    this.command,
    this.status,
    this.sections = const [],
    this.actions = const [],
    this.mono = false,
    this.live = false,
    this.below,
  });

  final String title;
  final String? command;
  final ActivityStatus? status;
  final List<ActivitySection> sections;
  final List<Widget> actions;
  final bool mono;

  /// Still arriving though the run is not [Run.going] here, as a job's log is.
  final bool live;
  final Widget? below;
}

/// A [LabelledActivity]'s label in the reply.
class RunLabel extends ConsumerWidget {
  const RunLabel({super.key, required this.activity, required this.run});

  final LabelledActivity activity;
  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = activity.view(ref, run);
    return ActivityLabel(
      icon: now.isError && now.markError ? Icons.error_outline : now.icon,
      text: now.label,
      isError: now.isError,
      iconWidget: now.busy ? labelSpinner(context) : null,
      onTap: () => activity.open(context, run),
    );
  }
}

class _RunCard extends ConsumerWidget {
  const _RunCard({
    required this.activity,
    required this.run,
    required this.source,
  });

  final LabelledActivity activity;
  final Run run;
  final ProviderListenable<LiveMessage>? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final from = source;
    final message = from == null ? null : ref.watch(from);
    final now =
        (message == null ? null : activity.follow(run, message)) ?? run.settled;
    final drawn = activity.view(ref, now);
    final shown = drawn.drawer(ref);
    return ActivityCard(
      title: shown.title,
      icon: drawn.icon,
      command: shown.command,
      status: shown.status,
      actions: shown.actions,
      sections: shown.sections,
      mono: shown.mono,
      live: shown.live || now.going,
      below: shown.below,
    );
  }
}

/// The call [id] names in [message] and the result answering it, as the
/// message now stands. Null where neither is in it.
({ToolCall? call, ToolResult? result})? _runIn(Message? message, String id) {
  if (message == null) return null;
  ToolCall? call;
  for (final part in message.parts) {
    if (part is ToolCallPart && part.toolCall.id == id) call = part.toolCall;
  }
  final result = message.toolResults[id];
  if (call == null && result == null) return null;
  return (call: call, result: result);
}
