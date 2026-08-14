import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/data/opencode/opencode_models.dart";

void main() {
  group("OcPart", () {
    test("parses text part", () {
      final json = {
        "id": "prt_abc",
        "type": "text",
        "text": "hello world",
      };
      final part = OcPart.fromJson(json);
      expect(part.type, "text");
      expect(part.text, "hello world");
      expect(part.id, "prt_abc");
    });

    test("parses tool part with completed state", () {
      final json = {
        "id": "prt_xyz",
        "type": "tool",
        "callID": "call_123",
        "tool": "bash",
        "state": {
          "status": "completed",
          "input": {"command": "ls -la"},
          "output": "total 0",
          "title": "ls -la",
          "metadata": {},
          "time": {"start": 100, "end": 200},
        },
      };
      final part = OcPart.fromJson(json);
      expect(part.type, "tool");
      expect(part.tool, "bash");
      expect(part.callID, "call_123");
      expect(part.state?["status"], "completed");
      expect((part.state?["input"] as Map)["command"], "ls -la");
    });

    test("parses tool part with error state", () {
      final json = {
        "type": "tool",
        "callID": "call_456",
        "tool": "read",
        "state": {
          "status": "error",
          "input": {"filePath": "/nonexistent"},
          "error": "File not found",
          "time": {"start": 100, "end": 101},
        },
      };
      final part = OcPart.fromJson(json);
      expect(part.state?["status"], "error");
      expect(part.state?["error"], "File not found");
    });

    test("round-trips through toJson", () {
      final original = {
        "type": "text",
        "id": "prt_1",
        "text": "hi",
      };
      final part = OcPart.fromJson(original);
      final out = part.toJson();
      expect(out["type"], "text");
      expect(out["text"], "hi");
      expect(out["id"], "prt_1");
    });
  });

  group("OcEvent", () {
    test("parses text delta event", () {
      final json = {
        "id": "evt_1",
        "type": "session.next.text.delta",
        "properties": {
          "sessionID": "ses_abc",
          "assistantMessageID": "msg_1",
          "textID": "txt_1",
          "delta": "hello",
          "timestamp": 1786739118776,
        },
      };
      final event = OcEvent.fromJson(json);
      expect(event.type, "session.next.text.delta");
      expect(event.properties["delta"], "hello");
      expect(event.properties["sessionID"], "ses_abc");
    });

    test("parses tool called event", () {
      final json = {
        "id": "evt_2",
        "type": "session.next.tool.called",
        "properties": {
          "sessionID": "ses_abc",
          "callID": "call_1",
          "tool": "bash",
          "input": {"command": "pwd"},
          "provider": {"executed": true},
          "timestamp": 1786739119336,
          "assistantMessageID": "msg_1",
        },
      };
      final event = OcEvent.fromJson(json);
      expect(event.type, "session.next.tool.called");
      expect(event.properties["tool"], "bash");
      expect(event.properties["callID"], "call_1");
      expect((event.properties["input"] as Map)["command"], "pwd");
    });

    test("parses tool success event", () {
      final json = {
        "id": "evt_3",
        "type": "session.next.tool.success",
        "properties": {
          "sessionID": "ses_abc",
          "callID": "call_1",
          "structured": {},
          "content": [],
          "provider": {"executed": true},
          "timestamp": 1786739121208,
          "assistantMessageID": "msg_1",
        },
      };
      final event = OcEvent.fromJson(json);
      expect(event.type, "session.next.tool.success");
      expect(event.properties["callID"], "call_1");
    });

    test("parses session idle event", () {
      final json = {
        "id": "evt_4",
        "type": "session.idle",
        "properties": {"sessionID": "ses_abc"},
      };
      final event = OcEvent.fromJson(json);
      expect(event.type, "session.idle");
      expect(event.properties["sessionID"], "ses_abc");
    });

    test("parses step ended event", () {
      final json = {
        "id": "evt_5",
        "type": "session.next.step.ended",
        "properties": {
          "sessionID": "ses_abc",
          "assistantMessageID": "msg_1",
          "finish": "stop",
          "cost": 0.001,
          "tokens": {
            "input": 100,
            "output": 50,
            "reasoning": 0,
            "cache": {"read": 0, "write": 0},
          },
          "timestamp": 1786739121208,
        },
      };
      final event = OcEvent.fromJson(json);
      expect(event.type, "session.next.step.ended");
      expect(event.properties["finish"], "stop");
      expect(event.properties["cost"], 0.001);
    });
  });

  group("parseSseEvents", () {
    test("parses data frames from SSE lines", () {
      final lines = Stream.fromIterable([
        "event: message",
        "data: {\"type\":\"session.idle\",\"id\":\"evt_1\",\"properties\":{\"sessionID\":\"ses_1\"}}",
        "",
        "data: {\"type\":\"session.next.text.delta\",\"id\":\"evt_2\",\"properties\":{\"delta\":\"hi\",\"sessionID\":\"ses_1\",\"assistantMessageID\":\"m1\",\"textID\":\"t1\",\"timestamp\":1}}",
        "",
      ]);
      final events = parseSseEvents(lines);
      expect(
        events,
        emitsInOrder([
          predicate<OcEvent>((e) => e.type == "session.idle"),
          predicate<OcEvent>((e) => e.type == "session.next.text.delta"),
        ]),
      );
    });

    test("ignores non-data lines", () async {
      final lines = Stream.fromIterable([
        ": comment",
        "event: ping",
        "",
        "data: ${jsonEncode({"type": "session.idle", "id": "x", "properties": {}})}",
        "",
      ]);
      final events = await parseSseEvents(lines).toList();
      expect(events.length, 1);
      expect(events.first.type, "session.idle");
    });
  });

  group("OcMessage", () {
    test("parses full message with parts", () {
      final json = {
        "info": {
          "id": "msg_1",
          "role": "assistant",
          "time": {"created": 100, "completed": 200},
          "modelID": "claude-sonnet-4-5-20250929",
          "providerID": "anthropic",
        },
        "parts": [
          {"type": "text", "id": "prt_1", "text": "hello"},
          {
            "type": "tool",
            "id": "prt_2",
            "callID": "call_1",
            "tool": "bash",
            "state": {"status": "completed"},
          },
        ],
      };
      final msg = OcMessage.fromJson(json);
      expect(msg.info.id, "msg_1");
      expect(msg.info.role, "assistant");
      expect(msg.info.modelID, "claude-sonnet-4-5-20250929");
      expect(msg.parts.length, 2);
      expect(msg.parts[0].text, "hello");
      expect(msg.parts[1].tool, "bash");
    });
  });
}