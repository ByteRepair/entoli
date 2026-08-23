import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/sync/protocol.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final state = ChatState(
    id: "c1",
    title: "Sync me",
    createdAt: DateTime.utc(2026, 8, 22, 10),
    updatedAt: DateTime.utc(2026, 8, 22, 11),
    project: null,
  );
  final record = ChatRecord.message(
    id: "m1",
    role: MessageRole.user,
    createdAt: DateTime.utc(2026, 8, 22, 10, 1),
  );

  /// Encode, decode, expect the same message back. The wire is JSON, so the
  /// comparison is on the decoded union — freezed equality over every field.
  /// [ChatMeta] has no `==`, so arms carrying one are compared by hand.
  void roundTrips(SyncMessage message) {
    final back = SyncMessage.fromJson(message.toJson());
    if (message is SyncChatSnapshot && back is SyncChatSnapshot) {
      expect(back.chatId, message.chatId);
      expect(back.state, message.state);
      expect(back.meta.model, message.meta.model);
      return;
    }
    if (message is SyncMetaPatch && back is SyncMetaPatch) {
      expect(back.chatId, message.chatId);
      expect(back.meta.model, message.meta.model);
      return;
    }
    expect(back, equals(message), reason: "${message.runtimeType} lost a field");
  }

  test("every handled arm survives a round trip", () {
    roundTrips(SyncMessage.welcome(chats: [state]));
    roundTrips(const SyncMessage.chatsChanged(chats: []));
    roundTrips(const SyncMessage.chatOpen(chatId: "c1", fromLine: 7));
    roundTrips(SyncMessage.chatSnapshot(
      chatId: "c1",
      state: state,
      meta: ChatMeta(model: "m", tempChatTtl: null),
    ));
    roundTrips(SyncMessage.recordAppend(chatId: "c1", records: [record]));
    roundTrips(SyncMessage.stateDiff(chatId: "c1", state: state));
    roundTrips(SyncMessage.metaPatch(chatId: "c1", meta: ChatMeta()));
    roundTrips(const SyncMessage.chatDeleted(chatId: "c1"));
    roundTrips(const SyncMessage.chatMoved(chatId: "c1", project: "other"));
    roundTrips(const SyncMessage.resourceRequest(
        id: "r0", chatId: "c1", resource: "img.png"));
    roundTrips(const SyncMessage.resourceChunk(
        id: "r0", bytesB64: "aGk=", done: true));
    roundTrips(const SyncMessage.ping());
    roundTrips(const SyncMessage.pong());
  });

  test("defaults survive omission", () {
    final open =
        SyncMessage.fromJson({"runtimeType": "chatOpen", "chatId": "c1"});
    expect(open, equals(const SyncMessage.chatOpen(chatId: "c1")));
    final chunk = SyncMessage.fromJson(
        {"runtimeType": "resourceChunk", "id": "r0", "bytesB64": ""});
    expect(chunk,
        equals(const SyncMessage.resourceChunk(id: "r0", bytesB64: "")));
  });

  test("the control arms travel too", () {
    roundTrips(const SyncMessage.controlState(chatId: "c1"));
    roundTrips(const SyncMessage.controlState(chatId: "c1", holder: "d1"));
    roundTrips(const SyncMessage.controlRequest(chatId: "c1"));
    roundTrips(const SyncMessage.controlGrant(chatId: "c1", granted: true));
    roundTrips(const SyncMessage.controlRelease(chatId: "c1"));
    roundTrips(const SyncMessage.promptSend(chatId: "c1", text: "hi"));
    roundTrips(const SyncMessage.approvalRespond(
        chatId: "c1", approvalId: "a", allow: false));
    roundTrips(const SyncMessage.questionsRespond(
        chatId: "c1", requestId: "q", answers: [null]));
    roundTrips(const SyncMessage.turnAbort(chatId: "c1"));
    roundTrips(const SyncMessage.turnResume(chatId: "c1"));
  });

  test("a turn's pending work travels whole", () {
    roundTrips(const SyncMessage.turnState(chatId: "c1"));
    roundTrips(const SyncMessage.turnState(
      chatId: "c1",
      running: true,
      approvals: [ToolApproval(id: "a1", toolName: "bash", argumentsText: "ls")],
      asks: [SyncAsk(id: "q1", argumentsJson: '{"question":"which?"}')],
      status: "Thinking",
      retry: "attempt 2",
    ));
  });
}
