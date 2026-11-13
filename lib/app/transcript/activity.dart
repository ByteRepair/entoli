import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../domain/models.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../settings/spec.dart" show SettingReader;
import "hand_off.dart";

/// What an icon in the conversation stands for. Each frontend picks its own
/// picture for each, in one exhaustive switch.
enum TranscriptGlyph {
  terminal,
  thinking,
  file,
  edit,
  search,
  web,
  subAgent,
  question,
  permissionGranted,
  permissionDenied,
  plan,
  artifact,
  skill,
  folderAdd,
  shield,
  error,
  goalActive,
  goalPaused,
  goalMet,
  goalBlocked,
  goalResumed,
  goalCleared,
  info,
}

/// Which kind of activity each part of a message is. The transcript asks it
/// and knows none of the kinds: a reply is made of activities, and one of
/// them, a sub-agent's, holds a transcript of its own — a composite that
/// stays acyclic with the builder depending on this rather than on the
/// kinds. `TranscriptActivities` answers, bound where the app is assembled.
abstract interface class ActivityCatalog {
  /// The kind [part] is, or null for a part that is not one — text, an
  /// error, a file, a command the user ran.
  Activity? of(MessagePart part);
}

final activityCatalogProvider = Provider<ActivityCatalog>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);

/// A message as it stands now, for a detail left open while its turn runs.
/// [running] is the room's: a block or a call with no end yet is live only
/// while a turn is.
typedef LiveMessage = ({Message? message, String? shellOutput, bool running});

/// Message [id] of [view] as a detail follows it.
LiveMessage liveMessageOf(ChatViewState view, String id) => (
  message: view.chat?.messages.where((m) => m.id == id).firstOrNull,
  shellOutput: view.shellOutput[id],
  running: view.isRunning,
);

/// Anything among the activities of a reply: a tool run, a thinking block,
/// an instruction file read, a permission answered, an artifact. One class
/// per kind, holding no state; what one is drawn from is a [Run]. A kind
/// says what it is on screen ([node]) and what is behind it ([detail]), as
/// data, and every frontend draws those.
abstract class Activity {
  const Activity();

  /// Stands on a row of its own rather than joining the run of activities
  /// that collapses behind one toggle: what the turn stopped to show.
  bool important(Run run) => false;

  /// What the reply shows for [run].
  ActivityNode node(SettingReader reader, Run run);

  /// What is behind [run]: its detail page. Null for a kind whose node is
  /// the whole of it — an artifact's card opens the artifact instead.
  ActivityDetail? detail(SettingReader reader, Run run) => null;

  /// [run] as [now], the message it is in, holds it, for a detail left open
  /// while its turn runs; null where the message does not hold it. A tool
  /// run is found by its call.
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

  /// The detail as it stands, following [source] where there is one: what
  /// an open detail page is redrawn from.
  ActivityDetail? detailFollowing(
    SettingReader reader,
    Run run,
    ProviderListenable<LiveMessage>? source,
  ) {
    final live = source == null ? null : reader.watch(source);
    final now = (live == null ? null : follow(run, live)) ?? run.settled;
    final shown = detail(reader, now);
    if (shown == null) return null;
    return now.going ? shown.asLive() : shown;
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
  /// running pill opening a detail before the call is followed.
  final ToolCall? call;

  /// Null while the tool is still running.
  final ToolResult? result;

  /// What a run that is not a call is drawn from: a thinking block, an
  /// instruction read, a permission, an artifact.
  final MessagePart? part;

  /// Where [part] sits in its message, which is what an open detail finds it
  /// by as it grows.
  final int? at;

  /// What a running command has printed so far, standing in for the output
  /// it has not returned yet.
  final String? printing;

  /// Still going where it is drawn: a tool the turn is running, the label of
  /// a waiting turn that has already said something — the spinner below the
  /// message handles the no-text-yet case — or a thinking block being
  /// written; in a detail, one following a turn still running it.
  final bool going;

  bool get failed => (result?.returnCode ?? 0) != 0;

  /// As a detail with nothing to follow shows it: done arriving.
  Run get settled => Run(
    chatId: chatId,
    callId: callId,
    call: call,
    result: result,
    part: part,
    at: at,
  );
}

/// What an activity is on screen. A sealed set, each a kind of drawing
/// rather than a kind of activity, so a frontend's switch over them stays
/// short and a new one is a compile error in every frontend until it draws
/// it. Each knows the activity and run it came from, so opening it needs
/// nothing else.
sealed class ActivityNode {
  const ActivityNode(this.activity, this.run);

  final Activity activity;
  final Run run;

  ActivityDetail? detail(
    SettingReader reader, {
    ProviderListenable<LiveMessage>? source,
  }) => activity.detailFollowing(reader, run, source);
}

/// The one line most activities are: an icon, what happened, and whether it
/// failed or is still going. [tail] is the last of a thought being written,
/// streamed under the line.
final class LabelNode extends ActivityNode {
  const LabelNode(
    super.activity,
    super.run, {
    required this.glyph,
    required this.text,
    this.isError = false,
    this.markError = true,
    this.busy = false,
    this.tail,
  });

  final TranscriptGlyph glyph;
  final String text;
  final bool isError;

  /// An [isError] label shows the error mark in place of [glyph]; false
  /// where [glyph] already says how it went, as a permission's does.
  final bool markError;

  final bool busy;
  final String? tail;

  TranscriptGlyph get shownGlyph =>
      isError && markError ? TranscriptGlyph.error : glyph;
}

/// A small `write` or `edit`, drawn as the lines it took out and put in.
final class DiffNode extends ActivityNode {
  const DiffNode(
    super.activity,
    super.run, {
    required this.title,
    required this.removed,
    required this.added,
  });

  final String title;
  final List<String> removed;
  final List<String> added;
}

/// The plan put to the user, drawn as the plan.
final class PlanNode extends ActivityNode {
  const PlanNode(super.activity, super.run, {required this.title});

  final String title;
}

enum OutputKind {
  artifact("Artifact"),
  skill("Skill");

  const OutputKind(this.caption);

  /// What the card is headed with.
  final String caption;
}

/// Something the turn made for the user, as a card to open: an artifact, a
/// skill to install. Opening it is [open], through the frontend's hand-off.
final class OutputNode extends ActivityNode {
  const OutputNode(
    super.activity,
    super.run, {
    required this.kind,
    required this.label,
    required this.open,
  });

  final OutputKind kind;
  final String label;
  final Future<void> Function(TranscriptHandOff handOff) open;
}

/// A status line under a detail's title: "Running · pid 4001", "Exit code 1".
class DetailStatus {
  const DetailStatus(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// One labelled block of a detail page. A section with nothing in it is
/// left out, so a tool that returned nothing shows no empty heading.
class DetailSection {
  const DetailSection({this.label, this.body, this.isError = false});

  final String? label;
  final String? body;
  final bool isError;

  bool get filled => body != null && body!.trim().isNotEmpty;
}

/// One thing a detail offers to do — Stop, Open log. [run] null is offered
/// but not on, [why] saying why.
class DetailAction {
  const DetailAction({required this.label, this.run, this.why});

  final String label;
  final Future<void> Function(TranscriptHandOff handOff)? run;
  final String? why;
}

/// What is behind an activity, whoever draws it: a title, the command set
/// apart, a status, sections, actions, and where there is one the transcript
/// it holds — a sub-agent's own reply.
class ActivityDetail {
  const ActivityDetail({
    required this.title,
    this.glyph,
    this.command,
    this.status,
    this.sections = const [],
    this.actions = const [],
    this.mono = false,
    this.live = false,
    this.transcript,
  });

  final String title;
  final TranscriptGlyph? glyph;
  final String? command;
  final DetailStatus? status;
  final List<DetailSection> sections;
  final List<DetailAction> actions;
  final bool mono;

  /// Still arriving: it keeps to the end of what is arriving, and its last
  /// section ends in a caret.
  final bool live;

  /// A sub-agent's transcript, drawn under the sections.
  final NestedTranscript? transcript;

  Iterable<DetailSection> get filled => sections.where((s) => s.filled);

  ActivityDetail asLive() => live
      ? this
      : ActivityDetail(
          title: title,
          glyph: glyph,
          command: command,
          status: status,
          sections: sections,
          actions: actions,
          mono: mono,
          live: true,
          transcript: transcript,
        );
}

/// A transcript inside a detail: the message, whether it is still being
/// written, and the source its own activities follow, so a label inside a
/// sub-agent's reply opens a detail that follows the sub-agent.
class NestedTranscript {
  const NestedTranscript({
    required this.chatId,
    required this.message,
    required this.running,
    required this.source,
  });

  final String chatId;
  final Message message;
  final bool running;
  final ProviderListenable<LiveMessage> source;
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
