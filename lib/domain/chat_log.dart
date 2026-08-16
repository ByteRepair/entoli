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
/// it grew by, not the whole of it again. [replay] is the only reader, and what
/// it produces is the conversation.

/// Why a turn stopped. Its **absence** is the interesting case: a log whose
/// last message has no [TurnEndRecord] was being written when the process
/// died, which is what makes it worth offering to continue.
enum TurnEnd {
  /// The model replied with no tool calls, or the stream closed on its own.
  done,

  /// The user pressed stop. Deliberately distinct from [error]: a turn someone
  /// chose to end is not one to offer to resume.
  aborted,

  /// The turn reported an error and gave up — a rejected key, a provider that
  /// stayed down, the step limit.
  error,
}

@freezed
sealed class ChatRecord with _$ChatRecord {
  /// A message begins. Its parts arrive as their own records, so the message
  /// can be written before anything has been said in it — which is what the
  /// empty assistant message at the head of a turn is.
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

  /// Forget [messageId] and everything after it. An edit or a regenerate,
  /// written rather than performed: truncating a log means rewriting it, which
  /// is the one thing this format is for not doing.
  const factory ChatRecord.rewind({required String messageId}) = RewindRecord;

  factory ChatRecord.fromJson(Map<String, dynamic> json) => _$ChatRecordFromJson(json);
}

/// Fold a log into the conversation it describes.
///
/// Liberal about what it cannot place: a part naming a message that is not
/// there, or an index past the end of one, is skipped rather than thrown on. A
/// log is written by a process that can be killed between any two lines, and
/// the reader's job is to salvage it.
List<Message> replay(Iterable<ChatRecord> records) {
  final messages = <Message>[];
  final at = <String, int>{};

  for (final record in records) {
    switch (record) {
      case MessageRecord(:final id, :final role, :final createdAt, :final parentId):
        at[id] = messages.length;
        messages.add(
            Message(id: id, role: role, createdAt: createdAt, parentId: parentId));

      case PartRecord(:final messageId, :final index, :final part):
        final into = at[messageId];
        if (into == null || index < 0 || index > messages[into].parts.length) continue;
        final parts = List<MessagePart>.of(messages[into].parts);
        if (index == parts.length) {
          parts.add(part);
        } else {
          parts[index] = part;
        }
        messages[into] = messages[into].copyWith(parts: parts);

      case AppendRecord(:final messageId, :final index, :final text):
        final into = at[messageId];
        if (into == null || index < 0 || index >= messages[into].parts.length) continue;
        final parts = List<MessagePart>.of(messages[into].parts);
        parts[index] = withMoreText(parts[index], text);
        messages[into] = messages[into].copyWith(parts: parts);

      case TurnEndRecord():
        // Read by the tail classifier, which decides whether to offer to
        // continue. It says nothing about what the conversation holds.
        break;

      case RewindRecord(:final messageId):
        final from = at[messageId];
        if (from == null) continue;
        messages.removeRange(from, messages.length);
        at.removeWhere((_, index) => index >= from);
    }
  }

  return messages;
}

/// The two parts an [AppendRecord] can land on, and what it does to them.
/// Anything else is left alone: only text grows a piece at a time.
MessagePart withMoreText(MessagePart part, String text) => switch (part) {
      TextPart(text: final had) => MessagePart.text(text: "$had$text"),
      ReasoningPart(text: final had, :final durationMs) =>
        MessagePart.reasoning(text: "$had$text", durationMs: durationMs),
      _ => part,
    };

/// The text [part] has beyond [was], when growing is the only thing that
/// happened to it. Null means it changed some other way and has to be written
/// whole — a thinking block being timed as it closes is the case that matters.
String? textGrownFrom(MessagePart was, MessagePart part) {
  final (String had, String now) = switch ((was, part)) {
    (TextPart(text: final a), TextPart(text: final b)) => (a, b),
    (ReasoningPart a, ReasoningPart b) when a.durationMs == b.durationMs => (a.text, b.text),
    _ => ("", ""),
  };
  if (now.length <= had.length || !now.startsWith(had)) return null;
  return now.substring(had.length);
}

/// The records [messages] are made of: each message, then each part it already
/// has. What writes a conversation assembled in memory; a turn appends its
/// records as they happen rather than going through this.
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
