import "package:flutter/material.dart";

import "../../../domain/ask.dart";

/// What stands where the composer does while the agent is waiting on an answer.
/// One question at a time, its options there to be clicked, and a bar saying
/// which of them this is.
///
/// The composer is gone for as long as it is up, so [onAnswered] is the only
/// way out: `Skip` takes it with whatever has been picked so far, which is how
/// a user who has nothing to say gets the turn moving again.
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
  late final List<String?> _answers =
      List.filled(widget.request.questions.length, null, growable: false);
  int _at = 0;

  List<AskQuestion> get _questions => widget.request.questions;

  void _pick(AskOption option) {
    setState(() {
      _answers[_at] = option.answer;
      if (_at < _questions.length - 1) _at++;
    });
    // The last answer submits: with nothing left to ask there is nothing for
    // the panel to move on to.
    if (_answers.every((a) => a != null)) widget.onAnswered(List.of(_answers));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = _questions[_at];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                "Question ${_at + 1} of ${_questions.length}",
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (_at > 0)
                TextButton.icon(
                  onPressed: () => setState(() => _at--),
                  icon: const Icon(Icons.arrow_back, size: 15),
                  label: const Text("Back"),
                  style: _compact,
                ),
              TextButton(
                onPressed: () => widget.onAnswered(List.of(_answers)),
                style: _compact,
                child: const Text("Skip"),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (_at + 1) / _questions.length,
              minHeight: 3,
            ),
          ),
          const SizedBox(height: 12),
          Text(question.question, style: theme.textTheme.titleSmall),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every button in the bar sits on one line with the count, so none of them
/// takes the height a button would rather have.
final ButtonStyle _compact = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 8),
  minimumSize: Size.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.option, required this.isPicked, required this.onTap});

  final AskOption option;

  /// Answered already, and come back to with `Back`.
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.label,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
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
        ),
      ),
    );
  }
}
