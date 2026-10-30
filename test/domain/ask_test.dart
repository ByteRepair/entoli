import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/ask.dart";

void main() {
  group("the shape we asked for", () {
    test("a batch of questions comes back in the order it was written", () {
      final questions = askQuestionsFrom(
        jsonEncode({
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
        }),
      );

      expect(questions.map((q) => q.question), [
        "Which database?",
        "Migrate the old rows?",
      ]);
      expect(questions.first.summary, "Both are already in the stack.");
      expect(questions.first.options.map((o) => o.label), [
        "Postgres",
        "SQLite",
      ]);
      expect(
        questions.first.options.first.detail,
        "Already running in staging.",
      );
      expect(questions.first.options.last.detail, isNull);
    });

    test("an option answers with its label unless it named something else", () {
      final questions = askQuestionsFrom(
        jsonEncode({
          "question": "Ship it?",
          "options": [
            {"label": "Yes"},
            {"label": "Not yet", "value": "hold"},
          ],
        }),
      );

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

    test(
      "the top-level question is read whole: wording, summary, clickable answers",
      () {
        final questions = askQuestionsFrom(decomposition);
        final options = questions.single.options;

        expect(questions, hasLength(1));
        expect(
          questions.single.question,
          startsWith("Understand the complete history"),
        );
        expect(questions.single.summary, startsWith("Decompose the question"));
        expect(options.map((o) => o.label), [
          "historical origins",
          "recent advances",
        ]);
        expect(
          options.first.detail,
          "Identify foundational papers and early work.",
        );
        // The label is for reading; the query is the form the model can use.
        expect(
          options.first.answer,
          "partial equivalence checking history origins",
        );
      },
    );

    test("a bare list of strings is a list of answers", () {
      final questions = askQuestionsFrom(
        jsonEncode({
          "question": "Which one?",
          "choices": ["first", "second"],
        }),
      );

      expect(questions.single.options.map((o) => o.answer), [
        "first",
        "second",
      ]);
    });
  });

  group("nothing askable", () {
    test("nothing clickable is not a question", () {
      // No options: nothing to click.
      expect(askQuestionsFrom(jsonEncode({"question": "What now?"})), isEmpty);
      // Options with no question: nothing to answer about.
      expect(
        askQuestionsFrom(
          jsonEncode({
            "options": [
              {"label": "Yes"},
            ],
          }),
        ),
        isEmpty,
      );
    });

    test("arguments that are not JSON at all", () {
      expect(askQuestionsFrom("{oops"), isEmpty);
      expect(askQuestionsFrom(""), isEmpty);
      expect(askQuestionsFrom(null), isEmpty);
    });
  });

  group("the answers", () {
    const asked = [
      AskQuestion(
        question: "Which database?",
        options: [AskOption(label: "Postgres")],
      ),
      AskQuestion(
        question: "Migrate?",
        options: [AskOption(label: "Yes")],
      ),
    ];

    test("survive the round trip, in the order they were asked", () {
      expect(askAnswersFrom(askAnswers(asked, ["Postgres", null])), [
        "Postgres",
        null,
      ]);
    });

    test("names every question, and says plainly when none were given", () {
      final written = askAnswers(asked, ["Postgres", null]);

      // Both questions are named, so the model sees the one it did not get.
      expect(written, contains("Which database?"));
      expect(written, contains("Migrate?"));
      expect(written, isNot(contains("answered nothing")));

      // Nothing given at all: the note says so.
      expect(askAnswers(asked, [null, null]), contains("answered nothing"));
    });

    test("a result that never arrived is no answers at all", () {
      expect(askAnswersFrom(null), isEmpty);
      expect(askAnswersFrom("not json"), isEmpty);
    });
  });
}
