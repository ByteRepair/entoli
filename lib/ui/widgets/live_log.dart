import "package:flutter/material.dart";
import "package:entoli_core/view/chat/widgets/shell_run.dart"
    show LiveShellOutput;

import "../../app/live_log.dart";

export "../../app/live_log.dart" show LiveLog;

/// [log] folded under a "Log" row until it is opened, and nothing at all while
/// the log is empty. Opened, it follows the log as it grows.
class LogPanel extends StatelessWidget {
  const LogPanel(this.log, {super.key, this.title = "Log"});

  final LiveLog log;
  final String title;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: log,
    builder: (context, _) => log.isEmpty
        ? const SizedBox.shrink()
        : ExpansionTile(
            title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
            shape: const Border(),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SelectionArea(child: LiveShellOutput(code: log.text)),
              ),
            ],
          ),
  );
}
