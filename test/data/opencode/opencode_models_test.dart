import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/data/opencode/opencode_models.dart";

void main() {

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

}