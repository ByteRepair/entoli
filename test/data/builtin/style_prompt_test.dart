import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/tone.dart";
import "package:agent_chat/data/builtin/tools/agent_tool.dart";
import "package:agent_chat/data/builtin/system_prompt.dart";

void main() {
  // The style prose is in the cacheable body under the capability sections, so
  // both arms — shell and browser — are asked the same things.
  String promptWith({Tone tone = Tone.none, bool citations = false}) =>
      agentSystemMessage(
        platform: "test",
        profile: null,
        tone: tone,
        citations: citations,
      ).text;

  group("style", () {
    test("the browser prompt carries the style section too", () {
      final text = systemPrompt(
        platform: "browser",
        offer: const ToolOffer(
          caps: AgentCapabilities(
            commands: false,
            webSearch: true,
            ask: true,
            task: false,
            artifact: true,
            createSkill: false,
          ),
        ),
      );

      expect(text, contains("## Style"));
    });
  });

  group("tone", () {
    test("a preset renders its sentence", () {
      final text = promptWith(tone: Tone.direct);

      expect(text, contains("## How to reply"));
      expect(text, contains("directly and to the point"));
      expect(text, isNot(contains("warmly and encouragingly")));
    });

    test("each non-none tone has its own words", () {
      final sentences = Tone.values
          .where((t) => t != Tone.none)
          .map((t) => t.instruction!)
          .toSet();
      expect(sentences.length, Tone.values.length - 1);
      for (final sentence in sentences) {
        expect(promptWith().contains(sentence), isFalse);
      }
    });

    test("none renders nothing at all", () {
      expect(styleSection(Tone.none, false), "");
      expect(promptWith(tone: Tone.none), isNot(contains("## How to reply")));
    });
  });

  group("citations", () {
    test("on renders the rule beside the tone", () {
      final text = promptWith(tone: Tone.kind, citations: true);

      expect(text, contains("## How to reply"));
      expect(text, contains("number them in the text"));
      expect(text, contains("warmly and encouragingly"));
    });

    test("on renders the rule alone", () {
      final text = promptWith(citations: true);

      expect(text, contains("number them in the text"));
      expect(text, isNot(contains("warmly and encouragingly")));
    });
  });
}
