import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../activity/activity.dart";
import "../activity/tool_run.dart" show toolRunView;

/// How the chat shows one tool's calls: an [Activity] like any other above a
/// reply — the label and the drawer behind it, from [view] — plus what voice
/// mode says of a call and what the approval banner asks. One class per tool
/// that shows anything of its own; every other tool gets the defaults.
///
/// The chat draws from the log, so a call is matched to its UI by the name
/// the log recorded — a mirrored chat, or an old one, draws whatever this
/// device offers. Live data is the view's own business: it watches what it
/// reads through the ref it is handed, as a job's state is, and what only the
/// drawer reads inside the drawer's builder.
abstract class ToolUI extends LabelledActivity {
  const ToolUI();

  /// The tool's name, as the log records it.
  String get tool;

  /// What voice mode says the call did, or null to say nothing.
  String? get spoken => "Used $tool";

  /// The approval banner's icon and question for a call of this tool.
  (IconData, String) get approval => (Icons.shield_outlined, "Allow $tool?");

  @override
  RunView view(WidgetRef ref, Run run) => toolRunView(run);
}
