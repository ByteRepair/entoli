import "package:flutter/material.dart";

import "../../../domain/ask.dart";

/// What stands where the composer does while the agent is waiting on an answer.
/// One question at a time, its options there to be clicked, and a bar of
/// segments saying which of them this is and which have been answered.
///
/// Nothing is sent until the user says so. Picking the last option used to
/// submit the lot, which made the panel a form with no review: an answer given
/// two questions ago could not be revisited without the whole thing going off
/// the moment the last one was picked. The segments are the way back to any of
/// them, and [onAnswered] only ever runs from the button.
///
/// The composer is gone for as long as the panel is up, so that button is the
/// only way out: with nothing picked it reads `Skip` and answers nothing, which
/// is how a user who has nothing to say gets the turn moving again.
///
/// Every question ends in a field to type an answer of one's own, since the
/// composer is not there to say it in: options the model thought of are not
/// always the answer, and a plan's "not like this" is only useful with what
/// to change. Typing picks it; the text is the answer.
class QuestionPanel extends StatefulWidget {
  const QuestionPanel({super.key, required this.request, required this.onAnswered});

  final AskRequest request;

  /// One answer per question, in the order they were asked, null for each one
  /// left unanswered.
  final ValueChanged<List<String?>> onAnswered;

  @override
  State<QuestionPanel> createState() => _QuestionPanelState();
}

class _QuestionPanelState extends State<QuestionPanel> {
  late final List<String?> _answers = widget.request.unanswered;
  late final List<TextEditingController> _typed = [
    for (final _ in _questions) TextEditingController(),
  ];
  int _at = 0;

  List<AskQuestion> get _questions => widget.request.questions;

  @override
  void dispose() {
    for (final controller in _typed) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The answer at [at] is the typed one rather than an option's.
  bool _typedPicked(int at) =>
      _answers[at] != null &&
      _questions[at].options.every((o) => o.answer != _answers[at]);

  void _type(String text) => setState(
      () => _answers[_at] = text.trim().isEmpty ? null : text.trim());

  /// The typed answer, picked again from what is already in the field.
  void _pickTyped() => _type(_typed[_at].text);

  /// Picking moves on, which is the fast path through a batch. It stops at the
  /// last question rather than submitting there.
  void _pick(AskOption option) => setState(() {
        _answers[_at] = option.answer;
        if (_at < _questions.length - 1) _at++;
      });

  void _goTo(int at) => setState(() => _at = at);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = _questions[_at];
    final answeredNothing = _answers.every((a) => a == null);
    // Asked one thing, there is nowhere to move and nothing to count: a
    // `Question 1 of 1` over a single segment and two dead arrows is the `1/1`
    // and the two dead thread arrows the message actions leave out for the
    // same reason.
    final several = _questions.length > 1;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (several) ...[
              Text(
                "Question ${_at + 1} of ${_questions.length}",
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              _Segments(
                questions: _questions,
                answers: _answers,
                at: _at,
                onJump: _goTo,
              ),
              const SizedBox(height: 14),
            ],
            Text(question.question, style: theme.textTheme.titleMedium),
            if (question.summary != null) ...[
              const SizedBox(height: 4),
              Text(
                question.summary!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 10),
            // A long list of options must not push the conversation off screen,
            // so it scrolls inside the panel instead of growing it.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in question.options)
                      _OptionTile(
                        option: option,
                        isPicked: _answers[_at] == option.answer,
                        onTap: () => _pick(option),
                      ),
                    _TypedTile(
                      // One field per question, so moving between them keeps
                      // what was typed into each.
                      key: ValueKey(_at),
                      controller: _typed[_at],
                      isPicked: _typedPicked(_at),
                      onChanged: _type,
                      onTap: _pickTyped,
                      onSubmitted: () {
                        if (_at < _questions.length - 1) _goTo(_at + 1);
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (several) ...[
                  // Dead at either end rather than wrapping round, the way the
                  // arrows under a message with several threads are.
                  TextButton.icon(
                    onPressed: _at > 0 ? () => _goTo(_at - 1) : null,
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text("Back"),
                    style: _compact,
                  ),
                  TextButton.icon(
                    onPressed: _at < _questions.length - 1 ? () => _goTo(_at + 1) : null,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text("Next"),
                    style: _compact,
                  ),
                ],
                const Spacer(),
                // One button, because there is one action: send what has been
                // picked. Two names for it would be two promises, and only the
                // wording changes with what there is to send.
                FilledButton(
                  onPressed: () => widget.onAnswered(List.of(_answers)),
                  child: Text(answeredNothing ? "Skip" : "Send"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One segment per question: filled once it has an answer, and wider under the
/// one being asked. Tapping jumps, which is what makes an answer already given
/// something the user can go back and change.
///
/// The two facts are on two channels — colour for answered, height for where
/// you are — so neither is read out of the other.
class _Segments extends StatelessWidget {
  const _Segments({
    required this.questions,
    required this.answers,
    required this.at,
    required this.onJump,
  });

  final List<AskQuestion> questions;
  final List<String?> answers;
  final int at;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The panel paints its own background over the page's `Material`, so an
    // `InkWell` splashing on that one would splash underneath it. This is the
    // surface the ripple has to land on.
    return Material(
      type: MaterialType.transparency,
      child: Row(
        children: [
          for (var i = 0; i < questions.length; i++)
            Expanded(
              child: Tooltip(
                message: questions[i].question,
                child: InkWell(
                  onTap: () => onJump(i),
                  // The bar itself is a few pixels tall, which nothing could
                  // hit; the row it sits in is what takes the tap.
                  child: SizedBox(
                    height: 20,
                    child: Center(
                      child: Container(
                        height: i == at ? 6 : 3,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: answers[i] != null
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Every button in the row sits on one line, so none of them takes the height a
/// button would rather have.
final ButtonStyle _compact = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 8),
  minimumSize: Size.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.option, required this.isPicked, required this.onTap});

  final AskOption option;

  /// Answered already, and come back to.
  final bool isPicked;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isPicked
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (option.detail != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          option.detail!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                // The tile's colour says this already, and says it in a hue a
                // reader who cannot separate it from the others is left with
                // nothing by.
                if (isPicked) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 18, color: theme.colorScheme.onPrimaryContainer),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The last row of every question: an answer the user writes themselves.
class _TypedTile extends StatelessWidget {
  const _TypedTile({
    super.key,
    required this.controller,
    required this.isPicked,
    required this.onChanged,
    required this.onTap,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool isPicked;
  final ValueChanged<String> onChanged;
  final VoidCallback onTap;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A press anywhere on it re-picks what it holds. A listener rather than
    // the field's own onTap, which a focused field does not report for
    // every tap.
    return Listener(
      onPointerDown: (_) => onTap(),
      child: Material(
        color: isPicked
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  onSubmitted: (_) => onSubmitted(),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    hintText: "Something else — type your own answer",
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              if (isPicked) ...[
                const SizedBox(width: 8),
                Icon(Icons.check, size: 18, color: theme.colorScheme.onPrimaryContainer),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
