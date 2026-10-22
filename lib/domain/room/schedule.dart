import "../models.dart";
import "../project_settings.dart" show OmadaOrdering;

/// One item of the room's schedule: what a member (or the main agent, where
/// the schedule names nobody) has been addressed to run. Either a user
/// prompt — already on the log where it was said while the room ran — or a
/// handoff, the reply that names the member. [generation] is the dispatch
/// wave the item belongs to: zero is the user's own, uncapped, and one and
/// up counts against the cap.
class ScheduledItem {
  ScheduledItem({this.userPrompt, this.reply, required this.generation})
      : assert((userPrompt == null) != (reply == null),
            "an item is a prompt or a handoff, never both or neither");

  final Message? userPrompt;
  final Message? reply;
  final int generation;
}

/// The room's order of speaking: one FIFO per member of what they have been
/// addressed to run, the replies a wave parked until it settles, and how deep
/// each finished turn ran. No I/O — the room hands [dispatch] the one thing
/// that does any, opening a turn.
///
/// Invariant: a member holds at most one waiting handoff. A later reply naming
/// them replaces it rather than queueing a second turn, since the turn reads
/// the whole room up to the newest; without it a room whose members all name
/// each other fans out by the member count every wave, and the generation cap
/// bounds depth, not breadth.
class Schedule {
  /// The null key is the main agent, who answers what no member was
  /// addressed for.
  final Map<String?, List<ScheduledItem>> _queues = {};

  /// The replies of turns that finished while a sibling was still speaking,
  /// in finish order: their handoffs wait for the settle the last one causes.
  final List<String> _parked = [];

  /// How deep the round ran when each reply finished, kept for the settle
  /// that reads it — the turn entries are gone from the table by then.
  final Map<String, int> _finished = {};

  bool _dispatching = false;
  bool _dispatchPending = false;

  bool get isEmpty => _queues.values.every((q) => q.isEmpty);

  /// Queue a user prompt for [members], or for the main agent where it names
  /// nobody.
  void addPrompt(List<String> members, Message prompt) {
    if (members.isEmpty) {
      (_queues[null] ??= []).add(ScheduledItem(userPrompt: prompt, generation: 0));
      return;
    }
    for (final member in members) {
      (_queues[member] ??= []).add(ScheduledItem(userPrompt: prompt, generation: 0));
    }
  }

  /// Hand [members] a turn on [reply], one generation past [generation].
  /// [thread] is the conversation, for which of two handoffs is the later. A
  /// reply naming nobody is the round ending, not the house speaking
  /// unprompted, so it queues nothing.
  ///
  /// Post: each of [members] holds exactly one waiting handoff.
  void addHandoff(List<String> members, Message reply,
      {required int generation, required List<Message> thread}) {
    for (final member in members) {
      final queue = _queues[member] ??= [];
      final waiting = queue.indexWhere((item) => item.reply != null);
      final deeper = waiting < 0 ? 0 : queue[waiting].generation;
      // The later of the two in the thread is the one kept: the turn's
      // history stops before its prompt, so the earlier must be inside it.
      final held = waiting < 0 ? null : queue[waiting].reply!;
      final later =
          held != null && thread.indexOf(held) > thread.indexOf(reply) ? held : reply;
      final next = ScheduledItem(
          reply: later,
          generation: deeper > generation + 1 ? deeper : generation + 1);
      if (waiting < 0) {
        queue.add(next);
      } else {
        queue[waiting] = next;
      }
    }
    assert(_oneHandoffEach());
  }

  /// Run what the schedule holds. Sequential order runs one item at a time —
  /// the first of the schedule, whatever member it names — and what follows
  /// dispatches at the settle it causes. Parallel order answers with one turn
  /// per member at once, each FIFO's head; relay the same, skipping a member
  /// with a turn in flight.
  ///
  /// A dispatched item is off its FIFO before [run] opens its turn, so a
  /// settle re-entering while the turn runs finds the schedule behind it and
  /// not the item running. Re-entering is real — a say landing mid-[run]
  /// reads the same queue — so a second call asks for a pass rather than
  /// running one beside it.
  ///
  /// [ordering] and [cap] are read at each pass, so a settings edit reaches
  /// the pass a re-entering dispatch asks for.
  ///
  /// Post: nothing past [cap] was run, and under relay nothing was run for a
  /// member [busy] named.
  Future<void> dispatch({
    required OmadaOrdering Function() ordering,
    required int Function() cap,
    required Set<String?> Function() busy,
    required Future<void> Function(String? member, ScheduledItem item) run,
  }) async {
    if (_dispatching) {
      _dispatchPending = true;
      return;
    }
    _dispatching = true;
    try {
      await _pass(ordering(), cap(), busy, run);
      while (_dispatchPending) {
        _dispatchPending = false;
        await _pass(ordering(), cap(), busy, run);
      }
    } finally {
      _dispatching = false;
    }
  }

  Future<void> _pass(
    OmadaOrdering ordering,
    int cap,
    Set<String?> Function() busy,
    Future<void> Function(String?, ScheduledItem) run,
  ) async {
    var started = 0;
    for (final member in _queues.keys.toList()) {
      final items = _queues[member];
      if (items == null || items.isEmpty) {
        if (items != null) _queues.remove(member);
        continue;
      }
      // The cap stops a member's handoff wave, not the user's words: a capped
      // head is dropped and the generation zero item behind it kept.
      final item = items.first;
      if (item.generation > 0 && item.generation >= cap) {
        items.removeAt(0);
        if (items.isEmpty) _queues.remove(member);
        continue;
      }
      if (!ordering.admits(
          started: started, memberBusy: busy().contains(member))) {
        continue;
      }
      items.removeAt(0);
      if (items.isEmpty) _queues.remove(member);
      started++;
      await run(member, item);
    }
  }

  /// [replyId]'s turn has left the table at [generation]: the depth its
  /// handoff will land one past.
  void finished(String replyId, int generation) => _finished[replyId] = generation;

  /// A reply that finished while a sibling still speaks waits for the wave.
  void park(String replyId) => _parked.add(replyId);

  /// The replies the settle hands off from, in the order they finished — the
  /// parked ones, then [own] — and forgets the depth of every other.
  List<String> settle(String? own) {
    final ids = [..._parked, ?own];
    _parked.clear();
    _finished.removeWhere((id, _) => !ids.contains(id));
    return ids;
  }

  /// How deep the round ran when [replyId] finished; zero where unknown.
  int generationOf(String replyId) => _finished[replyId] ?? 0;

  /// An interruption drops what is queued and keeps the wave's bookkeeping:
  /// the turns are carried on, not the round restarted.
  void clearQueues() => _queues.clear();

  /// An aborted or failed round is a stopped one: nothing queued, nothing
  /// parked to hand off from.
  void clear() {
    _queues.clear();
    _parked.clear();
    _finished.clear();
  }

  bool _oneHandoffEach() =>
      _queues.values.every((q) => q.where((i) => i.reply != null).length <= 1);
}
