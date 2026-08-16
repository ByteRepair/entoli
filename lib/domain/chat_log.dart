import "dart:convert";

import "package:freezed_annotation/freezed_annotation.dart";

import "models.dart";

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
/// What the log describes is a tree, not a list. An edit or a regenerate writes
/// a [BranchRecord] and then the message it introduces, so the turn it replaces
/// is still there to be read; [replayTree] folds the whole tree and walks the
/// one thread through it that is on screen. A log holding no [BranchRecord] is
/// a tree of one thread, which is what every log written before this was.

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
  /// stayed down, the step limit.
  error,
}

extension ResumableTurn on TurnEnd {
  /// Whether a turn that ended this way is one to offer to carry on. Nobody
  /// chose to end an [TurnEnd.error], which is why it is offered and
  /// [TurnEnd.aborted] is not. Here rather than at the two places that ask —
  /// the log's reader and the controller closing a turn — which have to agree
  /// or the offer flickers on the next reload.
  bool get resumable => this == TurnEnd.error;
}

@freezed
sealed class ChatRecord with _$ChatRecord {
  /// A message begins. Its parts arrive as their own records, so the message
  /// can be written before anything has been said in it — which is what the
  /// empty assistant message at the head of a turn is.
  ///
  /// It goes on the end of the thread being read, unless a [BranchRecord] just
  /// said otherwise.
  const factory ChatRecord.message({
    required String id,
    required MessageRole role,
    required DateTime createdAt,
    String? parentId,
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
  const factory ChatRecord.turnEnd({
    required String messageId,
    required TurnEnd reason,
  }) = TurnEndRecord;

  /// The message about to be written is an alternative to [siblingOf] rather
  /// than a continuation of the conversation: an edit, or a regenerate.
  ///
  /// A record of its own rather than a parent named on the message, because the
  /// first message of a chat can be edited too and the thread that replaces it
  /// has no parent to name. It also leaves every log written before threads
  /// alone: holding none of these, each of its messages continues the one
  /// thread it has, which is what they meant when they were written.
  const factory ChatRecord.branch({
    required String messageId,
    required String siblingOf,
  }) = BranchRecord;

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

  factory ChatRecord.fromJson(Map<String, dynamic> json) => _$ChatRecordFromJson(json);
}

/// What a log describes: the one thread through it that is on screen, and the
/// alternatives the messages on that thread sit among.
class Replayed {
  const Replayed({required this.messages, required this.branches});

  /// The thread being read, oldest message first.
  final List<Message> messages;

  /// For each message in [messages] that has any, every message written as an
  /// alternative to it — oldest first, and including the one on the thread. A
  /// message that has none is absent rather than present on its own.
  final Map<String, List<String>> branches;
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
  final branching = <String, String>{};

  /// The child of [of] the thread runs through: the one last selected, or
  /// failing that the newest, since a thread just written is the one to read.
  String? through(String? of) {
    final kids = children[of];
    if (kids == null || kids.isEmpty) return null;
    final picked = shown[of];
    return picked != null && kids.contains(picked) ? picked : kids.last;
  }

  /// The end of the thread being read, which is where a message that is not a
  /// branch goes.
  String? tail() {
    String? at;
    while (true) {
      final next = through(at);
      if (next == null) return at;
      at = next;
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
      case MessageRecord(:final id, :final role, :final createdAt, :final parentId):
        final replaces = branching.remove(id);
        final under = replaces != null && nodes.containsKey(replaces)
            ? parent[replaces]
            : tail();
        parent[id] = under;
        (children[under] ??= []).add(id);
        // A thread just written is the one being read, until a [SelectRecord]
        // further down the log says the user cycled off it.
        shown[under] = id;
        nodes[id] =
            Message(id: id, role: role, createdAt: createdAt, parentId: parentId);

      case BranchRecord(:final messageId, :final siblingOf):
        branching[messageId] = siblingOf;

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

      case TurnEndRecord():
        // Read by the tail classifier, which decides whether to offer to
        // continue. It says nothing about what the conversation holds.
        break;

      case RewindRecord(:final messageId):
        if (nodes.containsKey(messageId)) forget(messageId);
    }
  }

  final messages = <Message>[];
  final branches = <String, List<String>>{};
  String? at;
  while (true) {
    final next = through(at);
    if (next == null) break;
    final node = nodes[next];
    if (node == null) break;
    messages.add(node);
    final kids = children[at]!;
    if (kids.length > 1) branches[next] = List.unmodifiable(kids);
    at = next;
  }

  return Replayed(messages: messages, branches: branches);
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
  );
}

/// Whether the log stops in the middle of a turn: the last message of the
/// thread being read is a reply, and nothing closed it. See "Carrying on an
/// interrupted turn" in CLAUDE.md for why only the last one is asked about.
///
/// Takes the replayed [messages] rather than replaying again: which messages a
/// rewind left live is [replayTree]'s to answer. A resumed turn writes a second
/// [TurnEndRecord] for the same message, so the last one wins.
bool endsUnfinished(List<Message> messages, List<ChatRecord> records) {
  final last = messages.lastOrNull;
  if (last == null || last.role != MessageRole.assistant) return false;
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
/// has. What writes a conversation assembled in memory; a turn appends its
/// records as they happen rather than going through this. One thread and no
/// branches, which is what a conversation held as a list can describe.
List<ChatRecord> recordsOf(List<Message> messages) => [
      for (final message in messages) ...[
        ChatRecord.message(
          id: message.id,
          role: message.role,
          createdAt: message.createdAt,
          parentId: message.parentId,
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
