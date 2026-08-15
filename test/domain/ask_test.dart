import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/ask.dart";

void main() {
  group("the shape we asked for", () {
    test("a batch of questions comes back in the order it was written", () {
      final questions = askQuestionsFrom(jsonEncode({
        "questions": [
          {
            "question": "Which database?",
            "summary": "Both are already in the stack.",
            "options": [
              {"label": "Postgres", "detail": "Already running in staging."},
              {"label": "SQLite"},
            ],
          },
          {
            "question": "Migrate the old rows?",
            "options": [
              {"label": "Yes"},
              {"label": "No"},
            ],
          },
        ],
      }));

      expect(questions.map((q) => q.question),
          ["Which database?", "Migrate the old rows?"]);
      expect(questions.first.summary, "Both are already in the stack.");
      expect(questions.first.options.map((o) => o.label), ["Postgres", "SQLite"]);
      expect(questions.first.options.first.detail, "Already running in staging.");
      expect(questions.first.options.last.detail, isNull);
    });

    test("an option answers with its label unless it named something else", () {
      final questions = askQuestionsFrom(jsonEncode({
        "question": "Ship it?",
        "options": [
          {"label": "Yes"},
          {"label": "Not yet", "value": "hold"},
        ],
      }));

      expect(questions.single.options.map((o) => o.answer), ["Yes", "hold"]);
    });
  });

  group("the shape the model actually sent", () {
    /// Verbatim from a run: one question at the top level, its answers under
    /// `angles`, each one a label, a query and a rationale.
    const decomposition = """
{
  "question": "Understand the complete history of partial equivalence checking.",
  "summary": "Decompose the question into complementary search angles.",
  "angles": [
    {
      "label": "historical origins",
      "query": "partial equivalence checking history origins",
      "rationale": "Identify foundational papers and early work."
    },
    {
      "label": "recent advances",
      "query": "latest developments partial equivalence checking 2020s",
      "rationale": "Capture state-of-the-art research."
    }
  ]
}""";

    test("a question written out at the top level is still one question", () {
      final questions = askQuestionsFrom(decomposition);

      expect(questions, hasLength(1));
      expect(questions.single.question, startsWith("Understand the complete history"));
      expect(questions.single.summary, startsWith("Decompose the question"));
    });

    test("whatever it called the answers, they are what can be clicked", () {
      final options = askQuestionsFrom(decomposition).single.options;

      expect(options.map((o) => o.label), ["historical origins", "recent advances"]);
      expect(options.first.detail, "Identify foundational papers and early work.");
      // The label is for reading; the query is the form the model can use.
      expect(options.first.answer, "partial equivalence checking history origins");
    });

    test("a bare list of strings is a list of answers", () {
      final questions = askQuestionsFrom(jsonEncode({
        "question": "Which one?",
        "choices": ["first", "second"],
      }));

      expect(questions.single.options.map((o) => o.answer), ["first", "second"]);
    });
  });

  group("nothing askable", () {
    test("a question with no options is not one, because nothing is clickable", () {
      expect(askQuestionsFrom(jsonEncode({"question": "What now?"})), isEmpty);
    });

    test("options with no question are not one either", () {
      expect(
          askQuestionsFrom(jsonEncode({
            "options": [
              {"label": "Yes"},
            ],
          })),
          isEmpty);
    });

    test("arguments that are not JSON at all", () {
      expect(askQuestionsFrom("{oops"), isEmpty);
      expect(askQuestionsFrom(""), isEmpty);
      expect(askQuestionsFrom(null), isEmpty);
    });
  });

  group("reading the answers back", () {
    test("one per question asked, in the order they were asked", () {
      final answers = askAnswersFrom(
        jsonEncode({
          "answers": [
            {"question": "Which database?", "answer": "Postgres"},
            {"question": "Migrate?", "answer": null},
          ],
        }),
        2,
      );

      expect(answers, ["Postgres", null]);
    });

    test("a result that never arrived leaves every question unanswered", () {
      expect(askAnswersFrom(null, 2), [null, null]);
      expect(askAnswersFrom("not json", 1), [null]);
    });
  });
}
