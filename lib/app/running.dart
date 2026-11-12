import "package:flutter/foundation.dart" show Listenable;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../domain/agent_browser.dart";
import "../domain/room/room_state.dart" show ChatViewState;
import "../domain/shell_job.dart" show firstLine;
import "../providers.dart";
import "mirror_controller.dart" show chatViewProvider;
import "settings/spec.dart" show SettingReader;
import "transcript/activities/command.dart" show JobActivity;
import "transcript/activities/task.dart" show SubAgentActivity;
import "transcript/activity.dart"
    show Activity, LiveMessage, Run, liveMessageOf;

/// What a chat has running beside the reply: the browser's tab, a
/// background job, a sub-agent. Each frontend words and draws its own.
enum RunningKind { browser, job, subAgent }

/// What opening a running thing opens, which each frontend does its own way.
sealed class RunningOpens {
  const RunningOpens();
}

/// The activity behind it and the run it is, an open detail of it following
/// [source].
final class OpensDetail extends RunningOpens {
  const OpensDetail(this.activity, this.run, {this.source});

  final Activity activity;
  final Run run;
  final ProviderListenable<LiveMessage>? source;
}

/// The chat's browser tab, watched live.
final class OpensBrowser extends RunningOpens {
  const OpensBrowser(this.browser, this.tab);

  final AgentBrowser browser;
  final BrowserTab tab;

  /// In a window of its own rather than over the chat: a browser not in the
  /// app's, or a tab whose input is not to be trusted to the card.
  bool get window => !browser.inApp || !tab.trustedInput;
}

/// One thing a chat has running beside the reply.
class RunningThing {
  const RunningThing({
    required this.kind,
    required this.name,
    required this.label,
    required this.tooltip,
    required this.opens,
    this.hidden = false,
    this.group,
    this.mono = false,
  });

  /// What it is, and its name — the page's host, the job's command, the
  /// sub-agent — for a frontend that words it itself.
  final RunningKind kind;
  final String name;

  /// The browser is hidden from the agent.
  final bool hidden;

  /// What it is gathered under with the rest of its kind, as a singular noun
  /// ("background task"); null for one that stands alone, ahead of the
  /// groups.
  final String? group;
  final String label;
  final String tooltip;
  final bool mono;
  final RunningOpens opens;
}

/// A kind of thing a chat can have running: what [chatId] has of it now,
/// watching through [ref] whatever it reads beyond [view].
typedef RunningSource =
    List<RunningThing> Function(
      SettingReader ref,
      ChatViewState view,
      String chatId,
    );

/// Every kind of thing a chat can have running, in the order shown: the
/// browser's tab, standing alone, ahead of the groups.
const runningSources = <RunningSource>[
  browserRunning,
  jobsRunning,
  subAgentsRunning,
];

/// The chat's browser tab, where it has one to show: not on a mirrored chat,
/// whose browser is the other device's. Not `configured`: that reads the
/// disk, and this is asked on every streamed delta.
BrowserTab? browserTabOf(AgentBrowser browser, bool mirrored, String chatId) =>
    !browser.available || mirrored ? null : browser.tab(chatId);

/// The chat's tab as the running row reads it: the page it is on and whether
/// it is hidden from the agent, null with no page open. Rebuilt as the tab
/// changes, which it says through listenables rather than providers.
final _browserTabProvider = Provider.autoDispose
    .family<({BrowserPage page, BrowserHold? hold, BrowserTab tab})?, String>((
      ref,
      chatId,
    ) {
      final tab = browserTabOf(
        ref.watch(agentBrowserProvider),
        ref.watch(isMirroredChatProvider(chatId)),
        chatId,
      );
      if (tab == null) return null;
      final changes = Listenable.merge([tab.page, tab.hold]);
      changes.addListener(ref.invalidateSelf);
      ref.onDispose(() => changes.removeListener(ref.invalidateSelf));
      final page = tab.page.value;
      if (page == null) return null;
      return (page: page, hold: tab.hold.value, tab: tab);
    });

String _where(BrowserPage page) {
  final host = Uri.tryParse(page.url)?.host ?? "";
  if (host.isNotEmpty) return host;
  return page.title.isNotEmpty ? page.title : "blank page";
}

/// The chat's browser tab, while one is open: standing alone, opening a live
/// view of the page.
List<RunningThing> browserRunning(
  SettingReader ref,
  ChatViewState view,
  String chatId,
) {
  final at = ref.watch(_browserTabProvider(chatId));
  if (at == null) return const [];
  final where = _where(at.page);
  return [
    RunningThing(
      kind: RunningKind.browser,
      name: where,
      hidden: at.hold != null,
      label:
          "Browser · $where"
          "${at.hold == null ? "" : " · hidden from the agent"}",
      tooltip: "Watch the agent's browser",
      opens: OpensBrowser(ref.read(agentBrowserProvider), at.tab),
    ),
  ];
}

/// The background jobs running, opening the job's detail.
List<RunningThing> jobsRunning(
  SettingReader ref,
  ChatViewState view,
  String chatId,
) => [
  for (final job in view.runningJobs.values)
    RunningThing(
      kind: RunningKind.job,
      name: firstLine(job.command),
      group: "background task",
      label: firstLine(job.command),
      mono: true,
      tooltip: "Background job ${job.id}",
      opens: OpensDetail(
        JobActivity(command: job.command, jobId: job.id),
        Run(chatId: chatId, callId: job.callId),
      ),
    ),
];

/// The sub-agents still running, opening the detail its label in the reply
/// opens and following the turn the same way. The event's prompt is cut for
/// the pill; the call, followed once it is written, has all of it.
List<RunningThing> subAgentsRunning(
  SettingReader ref,
  ChatViewState view,
  String chatId,
) => [
  for (final MapEntry(key: replyId, value: agents)
      in view.runningSubAgents.entries)
    for (final agent in agents)
      RunningThing(
        kind: RunningKind.subAgent,
        name: agent.agent,
        group: "sub-agent",
        label: "@${agent.agent}",
        tooltip: "Sub-agent @${agent.agent}",
        opens: OpensDetail(
          SubAgentActivity(agent: agent.agent, prompt: agent.prompt),
          Run(chatId: chatId, callId: agent.id),
          source: chatViewProvider(
            chatId,
          ).select((v) => liveMessageOf(v, replyId)),
        ),
      ),
];

/// What [chatId] has running, from each of [runningSources] in turn: the
/// things that stand alone, and the rest gathered by their group.
({List<RunningThing> alone, Map<String, List<RunningThing>> groups}) runningOf(
  SettingReader ref,
  ChatViewState view,
  String chatId,
) {
  final alone = <RunningThing>[];
  final groups = <String, List<RunningThing>>{};
  for (final source in runningSources) {
    for (final thing in source(ref, view, chatId)) {
      final group = thing.group;
      group == null ? alone.add(thing) : (groups[group] ??= []).add(thing);
    }
  }
  return (alone: alone, groups: groups);
}
