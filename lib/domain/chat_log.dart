import "dart:convert";

import "package:freezed_annotation/freezed_annotation.dart";

import "models.dart";
import "shell.dart";
import "wired_skill.dart";

part "chat_log.freezed.dart";
part "chat_log.g.dart";

/// `conv.jsonl` is a log of these, one per line, appended as a turn happens and
/// never rewritten. A document had to be written whole to stay parseable, so it
/// could only be written when a turn was over — and a turn killed halfway left
/// nothing. A line is complete the moment it is written, so the only thing a
/// kill can cost is whatever had not been appended yet.
///
/// Nothing here is mutable, so a part that changed is superseded rather than
/// edited: the same [PartRecord.index] written again wins. The exception is
/// text, which only ever grows and so is written as [AppendRecord] — the piece
/// it grew by, not the whole of it again.
///
/// What the log describes is a tree, not a list. An edit or a regenerate opens
/// a message that names what it stands beside, so the turn it replaces is still
/// there to be read; [replayTree] folds the whole tree and walks the one thread
/// through it that is on screen. A log whose messages all name nothing is a
/// tree of one thread, which is what every log written before this was.

/// Why a turn stopped. Its **absence** is the interesting case: a log whose
/// last message has no [TurnEndRecord] was being written when the process
/// died, which is what makes it worth offering to continue. See
/// [ResumableTurn.resumable].
enum TurnEnd {
  /// The model replied with no tool calls, or the stream closed on its own.
  done,

  /// The user pressed stop.
  aborted,

  /// The turn reported an error and gave up — a rejected key, a provider that
  /// stayed down.
  error,

  /// The agent hit its step limit without finishing. Resumable, like [error],
  /// but not an error: the turn ran out of steps, not because something broke.
  stepLimit,
}

extension ResumableTurn on TurnEnd {
  /// Whether a turn that ended this way is one to offer to carry on. Nobody
  /// chose to end an [TurnEnd.error] or hit [TurnEnd.stepLimit], which is why
  /// both are offered and [TurnEnd.aborted] is not. Here rather than at the two
  /// places that ask — the log's reader and the controller closing a turn —
  /// which have to agree or the offer flickers on the next reload.
  bool get resumable => this == TurnEnd.error || this == TurnEnd.stepLimit;
}

@freezed
sealed class ChatRecord with _$ChatRecord {
  /// A message begins. Its parts arrive as their own records, so the message
  /// can be written before anything has been said in it — which is what the
  /// empty assistant message at the head of a turn is.
  ///
  /// [siblingOf] names the message this one is an alternative to — an edit, or
  /// a regenerate. Null goes on the end of the thread being read, which is what
  /// every message in a log written before there were threads does.
  ///
  /// [replacesSibling] takes that one away rather than sitting beside it, which
  /// is what a turn stopped before it said anything gets: see
  /// `Chat.worthAThread`. It forgets whatever hangs below it, like a
  /// [RewindRecord] does, and is only ever written where nothing does.
  const factory ChatRecord.message({
    required String id,
    required MessageRole role,
    required DateTime createdAt,
    String? siblingOf,
    @Default(false) bool replacesSibling,
    /// See [Message.documents]. On the record that opens the message rather
    /// than a part of its own: it is about the message, not something in it.
    @Default({}) Map<String, String> documents,
    /// See [Message.author]. About the message, like [documents].
    String? author,
    /// See [Message.addressees]. About the message, like [documents].
    @Default([]) List<String> addressees,
    /// See [Message.omadaOn]. About the message, like [documents].
    bool? omadaOn,
  }) = MessageRecord;

  /// One part of a message. Written again with the same [index] to supersede
  /// it: that is how a part that changed in place — a thinking block being
  /// timed as it closes — is written without rewriting what came before it.
  const factory ChatRecord.part({
    required String messageId,
    required int index,
    required MessagePart part,
  }) = PartRecord;

  /// More text on the end of the part at [index]. What a reply being streamed
  /// writes, and the reason it is not a [PartRecord] each time: superseding the
  /// whole part every second costs the text once per second it streams for, so
  /// a local model answering slowly would write its reply a hundred times over
  /// — and every copy is decoded again on every open.
  const factory ChatRecord.append({
    required String messageId,
    required int index,
    required String text,
  }) = AppendRecord;

  /// The turn writing [messageId] is over. See [TurnEnd] for why the record
  /// matters more when it is missing.
  ///
  /// [addressees] is who an Omada reply handed to, sigils on: a reply's
  /// routing is only known once its text is, so it rides the close rather
  /// than the [MessageRecord] that opened it. Sets [Message.addressees].
  const factory ChatRecord.turnEnd({
    required String messageId,
    required TurnEnd reason,
    @Default([]) List<String> addressees,
  }) = TurnEndRecord;

  /// Read [messageId] rather than whichever of its siblings was being read.
  /// Appended as the user cycles through the threads at a branch, so which one
  /// they were on survives a reload; the last one written wins, the way a
  /// superseded part does.
  const factory ChatRecord.select({required String messageId}) = SelectRecord;

  /// Forget [messageId] and everything below it.
  ///
  /// This is what an edit or a regenerate wrote before there were threads, and
  /// its meaning did not have to change: in a conversation of one thread,
  /// everything below a message is everything after it. Now it is deleting a
  /// thread. Written rather than performed, because truncating a log means
  /// rewriting it, which is the one thing this format is for not doing.
  const factory ChatRecord.rewind({required String messageId}) = RewindRecord;

  /// A compaction: everything up to and including [upToMessageId] is
  /// summarized by [summary] for the model, and still on the log for the user
  /// to read. The record names the boundary rather than carrying the messages,
  /// so a rewind past it simply un-applies it — the projection of what is left
  /// is the whole conversation again.
  ///
  /// More than one of these can sit on a log. Each summarizes everything
  /// before it that is still live, and the projection reads only the last one
  /// whose boundary is on the thread — an earlier one is a shadow, kept so a
  /// reload shows the dividers the user saw. Written rather than performed for
  /// the same reason [RewindRecord] is: a summary is a line the log holds, not
  /// a state the log is left in.
  const factory ChatRecord.compaction({
    required String upToMessageId,
    required String summary,
  }) = CompactionRecord;

  factory ChatRecord.fromJson(Map<String, dynamic> json) => _$ChatRecordFromJson(json);
}

/// What a log describes: the one thread through it that is on screen, and the
/// alternatives the messages on that thread sit among.
class Replayed {
  const Replayed({
    required this.messages,
    required this.branches,
    this.compactions = const [],
  });

  /// The thread being read, oldest message first.
  final List<Message> messages;

  /// For each message in [messages] that has any, every message written as an
  /// alternative to it — oldest first, and including the one on the thread. A
  /// message that has none is absent rather than present on its own.
  final Map<String, List<String>> branches;

  /// The compaction markers on the thread being read, oldest first, each
  /// naming a message still on it. One whose boundary was rewound away is not
  /// here: a marker the projection could not apply is not one to draw.
  final List<ConversationCompaction> compactions;
}

/// Fold a log into the conversation it describes, and the thread of it to show.
///
/// Liberal about what it cannot place: a part naming a message that is not
/// there, an index past the end of one, a branch of a message that has since
/// been deleted. A log is written by a process that can be killed between any
/// two lines, and the reader's job is to salvage it.
Replayed replayTree(Iterable<ChatRecord> records) {
  final nodes = <String, Message>{};
  final parent = <String, String?>{};
  final children = <String?, List<String>>{};
  final shown = <String?, String>{};
  final compactions = <String, ConversationCompaction>{};

  /// The child of [of] the thread runs through: the one last selected, or
  /// failing that the newest, since a thread just written is the one to read.
  ///
  /// [shown] is only ever set to a child already in [children], and `forget`
  /// drops the two together, so there is nothing to check it against here.
  String? through(String? of) {
    final kids = children[of];
    if (kids == null || kids.isEmpty) return null;
    return shown[of] ?? kids.last;
  }

  /// The thread being read, oldest first. Walked from the root each time rather
  /// than kept, since a select or a delete can move it anywhere — which makes
  /// folding a log of n messages O(n·depth). Measured at a few milliseconds for
  /// a chat of several hundred, against a `decodeLog` of the same log costing
  /// more, so it is left as the shorter code.
  Iterable<String> thread() sync* {
    for (var at = through(null); at != null; at = through(at)) {
      yield at;
    }
  }

  void forget(String id) {
    final stack = [id];
    while (stack.isNotEmpty) {
      final at = stack.removeLast();
      stack.addAll(children.remove(at) ?? const []);
      nodes.remove(at);
      final of = parent.remove(at);
      children[of]?.remove(at);
      if (shown[of] == at) shown.remove(of);
    }
  }

  for (final record in records) {
    switch (record) {
      case MessageRecord(
          :final id,
          :final role,
          :final createdAt,
          :final siblingOf,
          :final replacesSibling,
          :final documents,
          :final author,
          :final addressees,
          :final omadaOn
        ):
        // A branch of a message that has since been deleted goes on the end
        // instead, which is where it would have gone naming nothing at all.
        final beside = siblingOf != null && nodes.containsKey(siblingOf) ? siblingOf : null;
        final under = beside == null ? thread().lastOrNull : parent[beside];
        parent[id] = under;
        (children[under] ??= []).add(id);
        // A thread just written is the one being read, until a [SelectRecord]
        // further down the log says the user cycled off it.
        shown[under] = id;
        nodes[id] = Message(
            id: id,
            role: role,
            createdAt: createdAt,
            documents: documents,
            author: author,
            addressees: addressees,
            omadaOn: omadaOn);
        // After this one has joined them, so what it replaces is still there to
        // be found — and so that one record says the whole of where a message
        // goes, with no second line to arrive in the right order.
        if (beside != null && replacesSibling) forget(beside);

      case SelectRecord(:final messageId):
        if (!nodes.containsKey(messageId)) continue;
        shown[parent[messageId]] = messageId;

      case PartRecord(:final messageId, :final index, :final part):
        final into = nodes[messageId];
        if (into == null || index < 0 || index > into.parts.length) continue;
        final parts = List<MessagePart>.of(into.parts);
        if (index == parts.length) {
          parts.add(part);
        } else {
          parts[index] = part;
        }
        nodes[messageId] = into.copyWith(parts: parts);

      case AppendRecord(:final messageId, :final index, :final text):
        final into = nodes[messageId];
        if (into == null || index < 0 || index >= into.parts.length) continue;
        final parts = List<MessagePart>.of(into.parts);
        parts[index] = withMoreText(parts[index], text);
        nodes[messageId] = into.copyWith(parts: parts);

      case TurnEndRecord(:final messageId, :final addressees):
        // Otherwise read by the tail classifier alone. A resumed turn closes
        // again, and the last close's routing is the reply's.
        final into = nodes[messageId];
        if (into == null || into.role != MessageRole.assistant) continue;
        nodes[messageId] = into.copyWith(addressees: addressees);

      case RewindRecord(:final messageId):
        if (nodes.containsKey(messageId)) forget(messageId);

      case CompactionRecord(:final upToMessageId, :final summary):
        // Applied where the boundary is still live; dropped as a record the
        // moment the rewind takes it away, like any other marker of what was
        // there. Keyed by the boundary, so a marker written twice for the
        // same message is the last one — the way a superseded part is.
        if (nodes.containsKey(upToMessageId)) {
          compactions[upToMessageId] = ConversationCompaction(
              upToMessageId: upToMessageId, summary: summary);
        }
    }
  }

  final messages = <Message>[];
  final branches = <String, List<String>>{};
  // Thread order, not log order: a marker's place on the screen is where its
  // boundary is, and this loop is already walking the thread. A boundary
  // rewound away is gone from [compactions] with the message it named, so
  // what is left here is live.
  final liveCompactions = <ConversationCompaction>[];
  for (final id in thread()) {
    messages.add(nodes[id]!);
    final kids = children[parent[id]]!;
    if (kids.length > 1) branches[id] = List.unmodifiable(kids);
    final marker = compactions[id];
    if (marker != null) liveCompactions.add(marker);
  }

  return Replayed(
      messages: messages, branches: branches, compactions: liveCompactions);
}

/// The thread a log describes. [replayTree] for the branches beside it.
List<Message> replay(Iterable<ChatRecord> records) => replayTree(records).messages;

/// The chat a log describes: the conversation, the threads beside it, and
/// whether it stops in the middle of a turn. Both stores load through here, so
/// one that reads the conversation and forgets the turn cannot exist.
Chat chatFrom(ChatState state, List<ChatRecord> records) {
  final replayed = replayTree(records);
  return Chat(
    state: state,
    messages: replayed.messages,
    branches: replayed.branches,
    unfinished: endsUnfinished(replayed.messages, records),
    compactions: replayed.compactions,
  );
}

/// Whether the log stops in the middle of a turn: the last message of the
/// thread being read is a reply, and nothing closed it. See "Carrying on an
/// interrupted turn" in AGENTS.md for why only the last one is asked about.
///
/// Takes the replayed [messages] rather than replaying again: which messages a
/// rewind left live is [replayTree]'s to answer. A resumed turn writes a second
/// [TurnEndRecord] for the same message, so the last one wins.
///
/// A turn the user opened with `!` is never offered, whatever closed it or
/// failed to. Resuming appends to the reply, and a command has nothing to
/// append: the only way to carry one on would be to run it a second time, which
/// is not continuing it. Without this, Continue on a killed `!ls` would resolve
/// a model and hand it the conversation — the one thing the syntax exists to
/// avoid. A `/skill` flagged `invocation: callback` is the same shape: a
/// callback turn appends nothing either.
bool endsUnfinished(List<Message> messages, List<ChatRecord> records) {
  final last = messages.lastOrNull;
  if (last == null || last.role != MessageRole.assistant) return false;
  // A sub-agent's transcript is the reply alone, so there is not always one.
  final prompt = messages.length < 2 ? null : messages[messages.length - 2];
  if (prompt != null && shellBypassCommand(prompt.plainText) != null) return false;
  // A wired-callback turn (`/compact`) appends nothing either. Matched by
  // name alone rather than against the library: this runs on a reload, where
  // what the skill's frontmatter says today is not what it said when the turn
  // was sent, and a name in the enum is the closed set the dispatch reads.
  // The one cost is a user's own template skill shadowing a wired name — its
  // interrupted turn is then not offered, where it would have been resumable;
  // a name in the enum is the app's own, and shadowing one is not a state
  // worth a stamp on every message for.
  if (prompt != null && wiredSkillFromText(prompt.plainText) != null) return false;
  TurnEnd? ended;
  for (final record in records) {
    if (record is TurnEndRecord && record.messageId == last.id) ended = record.reason;
  }
  return ended?.resumable ?? true;
}

/// The two parts an [AppendRecord] can land on, and what it does to them.
/// Anything else is left alone: only text grows a piece at a time.
MessagePart withMoreText(MessagePart part, String text) => switch (part) {
      TextPart(text: final had) => part.copyWith(text: "$had$text"),
      ReasoningPart(text: final had) => part.copyWith(text: "$had$text"),
      _ => part,
    };

/// The text [part] has beyond [was], when growing is the only thing that
/// happened to it. Null means it changed some other way and has to be written
/// whole — a thinking block being timed and signed as it closes is the case
/// that matters.
String? textGrownFrom(MessagePart was, MessagePart part) {
  final had = _growingText(was);
  final now = _growingText(part);
  if (had == null || now == null) return null;
  if (now.length <= had.length) return null;
  final grew = now.substring(had.length);
  // Asking [withMoreText] rather than comparing the fields by hand, so a field
  // added to a part cannot quietly start being dropped by an append.
  return withMoreText(was, grew) == part ? grew : null;
}

String? _growingText(MessagePart part) => switch (part) {
      TextPart(:final text) || ReasoningPart(:final text) => text,
      _ => null,
    };

/// The records [messages] are made of: each message, then each part it already
/// has. What writes a conversation assembled in memory, and what a turn opens
/// itself with; the rest of a turn is appended as it happens rather than going
/// through here.
///
/// [siblingOf] names what the first of them stands beside, which is the whole
/// of what makes a turn a thread rather than a continuation, and [replacing]
/// takes that one away rather than joining it. Left out, this describes one
/// thread and no branches — which is all a conversation held as a list can say.
List<ChatRecord> recordsOf(List<Message> messages,
        {String? siblingOf, bool replacing = false}) =>
    [
      for (final (at, message) in messages.indexed) ...[
        ChatRecord.message(
          id: message.id,
          role: message.role,
          createdAt: message.createdAt,
          documents: message.documents,
          author: message.author,
          addressees: message.addressees,
          omadaOn: message.omadaOn,
          siblingOf: at == 0 ? siblingOf : null,
          replacesSibling: at == 0 && replacing,
        ),
        for (final (index, part) in message.parts.indexed)
          ChatRecord.part(messageId: message.id, index: index, part: part),
      ],
    ];

/// The log's own encoding, so the one place that describes the format is the
/// one that reads and writes it.
String encodeLog(Iterable<ChatRecord> records) =>
    records.map((r) => "${jsonEncode(r.toJson())}\n").join();

/// Records out of a log, stopping at the first line that will not parse.
/// Appends are ordered, so a broken line is the one a kill landed in the middle
/// of and everything before it is whole — which is the reason the log is lines
/// rather than a document.
List<ChatRecord> decodeLog(String text) {
  final records = <ChatRecord>[];
  // `split` rather than `convert`: the whole file is already one string, and
  // materialising a list of every line again doubles that for nothing.
  for (final line in LineSplitter.split(text)) {
    if (line.isEmpty) continue;
    try {
      records.add(ChatRecord.fromJson(jsonDecode(line) as Map<String, dynamic>));
    } catch (_) {
      break;
    }
  }
  return records;
}
