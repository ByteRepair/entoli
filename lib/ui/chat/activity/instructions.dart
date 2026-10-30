import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;

import "../../../core/config.dart" show instructionFileName;
import "../../../domain/models.dart";
import "activity.dart";

/// The instruction files a turn was the first to read into the model's
/// context — the up-front `AGENTS.md` load, or a nested one a file read
/// pulled in. One label per read, on the part that records it; the drawer
/// says what was read and where each file sat, never what the files said —
/// the content rides the per-turn system prompt and the read results, and is
/// the model's, not the conversation's.
class InstructionsActivity extends LabelledActivity {
  const InstructionsActivity();

  /// Important like a permission: it changed what the model is working from,
  /// it happens at most once per file, and a collapse would hide the one
  /// moment the turn grew.
  @override
  bool important(Run run) => true;

  @override
  RunView view(WidgetRef ref, Run run) {
    final files = (run.part! as InstructionsPart).files;
    return RunView(
      icon: Icons.description_outlined,
      label: switch (files) {
        [final only] => "Read ${_basenameOf(only.path)}",
        final several => "Read ${several.length} instruction files",
      },
      drawer: (_) => RunDrawer(
        title: "Instructions",
        sections: [
          for (final ref in files)
            (
              label: instructionKindPhrase(ref.kind),
              body: ref.path,
              isError: false,
            ),
        ],
      ),
    );
  }
}

/// What a single file's label names it by: the bare name where it is an
/// instruction file proper, the path when it is anything else — a nested one
/// is clearer as where it sits.
String _basenameOf(String path) =>
    p.basename(path) == instructionFileName ? instructionFileName : path;
