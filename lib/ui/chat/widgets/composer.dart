import "package:flutter/material.dart";
import "package:flutter/services.dart";

class _SendIntent extends Intent {
  const _SendIntent();
}

/// Message composer with send/abort toggle. Calls onSend with the typed text
/// and clears the field; calls onAbort when a turn is running.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.isRunning,
    required this.onSend,
    required this.onAbort,
  });

  final TextEditingController controller;
  final bool isRunning;
  final ValueChanged<String> onSend;
  final VoidCallback onAbort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _SendIntent(),
                SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    _SendIntent(),
              },
              child: Actions(
                actions: {
                  _SendIntent: CallbackAction<_SendIntent>(
                    onInvoke: (_) => _submit(),
                  ),
                },
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: "Message...",
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          isRunning
              ? IconButton.filled(
                  onPressed: onAbort,
                  icon: const Icon(Icons.stop),
                  tooltip: "Stop",
                )
              : IconButton.filled(
                  onPressed: _submit,
                  icon: const Icon(Icons.send),
                  tooltip: "Send",
                ),
        ],
      ),
    );
  }

  void _submit() {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    onSend(text);
    controller.clear();
  }
}