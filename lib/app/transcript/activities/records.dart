import "package:path/path.dart" as p;

import "../../../core/config.dart" show instructionFileName;
import "../../../domain/artifact.dart";
import "../../../domain/models.dart";
import "../../../domain/permission.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

/// The instruction files a turn was the first to read into the model's
/// context — the up-front `AGENTS.md` load, or a nested one a file read
/// pulled in. One label per read; the detail says what was read and where
/// each file sat, never what the files said.
final class InstructionsActivity extends Activity {
  const InstructionsActivity();

  /// Important like a permission: it changed what the model is working
  /// from, it happens at most once per file, and a collapse would hide the
  /// one moment the turn grew.
  @override
  bool important(Run run) => true;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final files = (run.part! as InstructionsPart).files;
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.file,
      text: switch (files) {
        [final only] => "Read ${_basenameOf(only.path)}",
        final several => "Read ${several.length} instruction files",
      },
    );
  }

  @override
  ActivityDetail detail(SettingReader reader, Run run) => ActivityDetail(
    title: "Instructions",
    glyph: TranscriptGlyph.file,
    sections: [
      for (final ref in (run.part! as InstructionsPart).files)
        DetailSection(label: instructionKindPhrase(ref.kind), body: ref.path),
    ],
  );
}

/// The bare name where it is an instruction file proper, the path when it
/// is anything else — a nested one is clearer as where it sits.
String _basenameOf(String path) =>
    p.basename(path) == instructionFileName ? instructionFileName : path;

/// A permission banner the turn raised, once it is history: what was asked
/// and what was answered, read off the recorded part and the result the call
/// produced. "asked" without an answer is a turn that ended with the banner
/// up, which the deny-on-end recorded instead.
final class ApprovalActivity extends Activity {
  const ApprovalActivity();

  /// The user's own decision; a run of them collapsed behind a toggle the
  /// reader will never expand.
  @override
  bool important(Run run) => true;

  String _answer(ApprovalPart part) => switch (part.answer) {
    "asked" => "asked (never answered)",
    "allow" => "allowed",
    "alwaysAllowChat" => "allowed, always in this chat",
    "alwaysAllowProject" => "allowed, always in this project",
    "deny" => "denied",
    _ => part.answer,
  };

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final part = run.part! as ApprovalPart;
    // Raw answers, not the mapped wording: "deny" is what the enum records.
    final denied = part.answer == "deny" || part.answer == "asked";
    // The outcome names what stood behind the call's fate, the answer what
    // was pressed: on an "always" answer the two say the same thing, and a
    // re-prompt's result records the rerun the answer went on to, which the
    // first banner must not wear.
    final clause = switch (part.answer) {
      "alwaysAllowChat" || "alwaysAllowProject" || "asked" => null,
      _ when part.deniedDirs.isNotEmpty => null,
      _ => run.result?.permissionOutcome,
    };
    final answer = _answer(part);
    return LabelNode(
      this,
      run,
      glyph: denied
          ? TranscriptGlyph.permissionDenied
          : TranscriptGlyph.permissionGranted,
      text: clause == null
          ? "Permission: ${part.toolName} — $answer"
          : "Permission: ${part.toolName} — $answer ($clause)",
      isError: denied,
      markError: false,
    );
  }

  @override
  ActivityDetail detail(SettingReader reader, Run run) {
    final part = run.part! as ApprovalPart;
    final outcome = run.result?.permissionOutcome;
    return ActivityDetail(
      title: "Permission",
      glyph: TranscriptGlyph.shield,
      mono: true,
      sections: [
        DetailSection(label: part.toolName, body: part.argumentsText),
        if (part.deniedDirs.isNotEmpty)
          DetailSection(
            label: "Sandbox dirs granted",
            body: part.deniedDirs.join("\n"),
          ),
        DetailSection(label: "Answer", body: _answer(part)),
        if (outcome != null) DetailSection(label: "Outcome", body: outcome),
      ],
    );
  }
}

/// An `artifact` call, once it is history: a card the user taps to open the
/// page the model rendered. Output the user came for rather than activity,
/// so a card and not a label, and important. Its identity is in its part.
final class ArtifactActivity extends Activity {
  const ArtifactActivity();

  @override
  bool important(Run run) => true;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final ArtifactPart(:artifactId, :entryFile, :title) =
        run.part! as ArtifactPart;
    return OutputNode(
      this,
      run,
      kind: OutputKind.artifact,
      label: title.isEmpty ? "View artifact" : title,
      open: (handOff) => handOff.openArtifact(
        run.chatId,
        artifactId,
        entryFile: entryFile,
        title: title,
      ),
    );
  }
}

/// A `create_skill` call, once it is history: a card the user taps to review
/// and install the skill the model drafted. Important the way an artifact
/// is, for the same reason.
final class SkillInstallActivity extends Activity {
  const SkillInstallActivity();

  @override
  bool important(Run run) => true;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final SkillInstallPart(:installId, :title) = run.part! as SkillInstallPart;
    return OutputNode(
      this,
      run,
      kind: OutputKind.skill,
      label: title.isEmpty ? "Install skill" : title,
      open: (handOff) => handOff.installSkill(run.chatId, installId),
    );
  }
}

/// The `artifact` call itself; its card is the part's.
final class ArtifactToolActivity extends ToolActivity {
  const ArtifactToolActivity();

  @override
  String get tool => artifactToolName;

  @override
  String get spoken => "Made an artifact";
}

/// The directory grant: its banner is the whole grant.
final class AddDirectoryActivity extends ToolActivity {
  const AddDirectoryActivity();

  @override
  String get tool => addDirectoryName;

  @override
  (TranscriptGlyph, String) get approval =>
      (TranscriptGlyph.folderAdd, "Let the agent write here?");
}
