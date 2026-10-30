import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as p;

import "../../../core/formatting.dart";
import "../../../domain/agent_backend.dart";
import "../../../domain/chat_store.dart" show attachmentFilename;
import "../../../domain/file_tools.dart";
import "../../../domain/shell.dart";
import "../../../domain/tool_arg.dart";
import "../../../domain/workspace.dart" show isUnder;
import "../../mime.dart";
import "../approval_gate.dart";
import "../llm/llm_client.dart";
import "../llm/readable_client.dart" show pdfBudgetBytes;
import "../memory/instructions.dart";
import "../templates.dart" show systemProse;
import "agent_tool.dart";
import "turn.dart";

/// The types `read` hands to the model as the file itself rather than decoding
/// it as text: the images every provider takes, and PDFs.
const readBlockTypes = {
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "application/pdf",
};

/// Over this an image fails the whole request: Anthropic's limit is 5 MB, and
/// that is of the base64.
const maxReadImageBytes = 3750000;

/// What [bytes] are, where they are one of [readBlockTypes]. By their magic
/// number alone: a name says `.png` of a file that is not one just as easily,
/// and a block a provider cannot decode fails every request it stays in.
String? readBlockTypeOf(Uint8List bytes) {
  final type = sniffMime(bytes);
  return readBlockTypes.contains(type) ? type : null;
}

const _pathArg = {
  "type": "string",
  "description":
      "Workspace-relative path, `project:` + path for the project "
      "workspace, or an absolute path (asked of the user).",
};

/// Whether [path] is under the chat's attachments, which nothing changes.
bool _inAttachments(Turn turn, String path) =>
    turn.attachmentsDir != null && isUnder(path, turn.attachmentsDir!);

String _readOnlyAttachment(String path) =>
    "$path is an attachment, and attachments are read-only. Copy it with "
    "$attachmentSaveToolName and change the copy.";

/// Why [path] may not be changed yet — never read, or changed since — or
/// null where it may.
Future<String?> _unread(
  Turn turn,
  String path,
  String shownPath,
  String tool,
) => unreadFileProblem(
  path,
  shownPath: shownPath,
  toolName: tool,
  readFiles: turn.readFiles,
);

/// What the model wrote or read is what it has seen, so the next edit needs
/// no read.
Future<void> _stamp(Turn turn, String path) async {
  final stamp = fileStampOf(path);
  if (stamp != null) turn.readFiles[path] = stamp;
}

/// Run a file tool behind the workspace gate and answer [call] with how it
/// went: the workspaces and what was granted run, the machine is asked.
/// [ruleSubject] is what the rules match: the path, for `read`, `write` and
/// `edit`; for any other tool they match the tool alone.
Stream<AgentEvent> gatedFileRun(
  Turn turn,
  LlmToolCall call,
  String path,
  String tool,
  Future<ShellResult> Function() run, {
  String? ruleSubject,
}) async* {
  final outcome = GateOutcome();
  yield* turn.gate.path(
    call,
    path,
    tool,
    run,
    outcome,
    granted: (await turn.gate.permissions()).writableDirs,
    ruleSubject: ruleSubject,
  );
  yield ToolResultEvent(outcome.resultOf(call));
}

/// Read a file. A path the workspaces hold runs without asking, the way
/// `bash` reads in `never` mode; one that reaches past them is offered to
/// the user first, on the same terms a command is. An image or a PDF comes
/// back as itself where the model takes one, and the AGENTS.md above the file
/// comes with it.
///
/// The file tools are the floor: offered on every turn, since they work on
/// the app's own filesystem, which every platform has. This one carries their shared
/// words in the prompt.
class ReadTool extends AgentTool {
  ReadTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.files;

  @override
  String get name => readToolName;

  @override
  String get fragment =>
      "`read`/`write`/`edit` to work with files in the "
      "workspace";

  @override
  String get section => systemProse("files");

  @override
  String get description =>
      "Read a file from the workspace and return its "
      "contents with line numbers. Paths are relative to the workspace; "
      "prefix with `project:` to read from the project workspace; an absolute "
      "path reads the machine directly, and the user is asked before it runs. "
      "Use `offset` and `limit` (1-indexed) to read a slice of a large file. "
      "An image or a PDF comes back as itself, for you to look at, where this "
      "model can take one. Any AGENTS.md in the directories above the file "
      "comes back with it: follow those instructions.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "path": _pathArg,
      "offset": {
        "type": "integer",
        "description":
            "Line number to start reading from (1-indexed). "
            "Defaults to 1.",
      },
      "limit": {
        "type": "integer",
        "description": "Maximum number of lines to read.",
      },
    },
    "required": ["path"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final args = readArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* toolRejected(
        call,
        'The $readToolName tool takes {"path": "..."}; that argument was missing.',
      );
      return;
    }
    final path = turn.resolvePath(args.path);
    yield toolCalled(call, args.path);
    // Held beside the run rather than in it, for the event below: what the
    // read pulled in, if anything. Empty is the honest "nothing" — a denied
    // or gated read never ran, so it pulled nothing in.
    var nested = const <InstructionFile>[];
    // An image or PDF read, saved the way a screenshot is so it rides this
    // call's result on every reading of the conversation.
    ImageEvent? attached;
    Future<ShellResult> attach(String type, Uint8List bytes) async {
      final pdf = type == "application/pdf";
      // Not a failure: the file is there, and its path is what a command
      // needs to do what this model cannot.
      if (!(pdf ? turn.seesPdfs : turn.seesImages) || !turn.savesResources) {
        return ShellResult(
          returnCode: 0,
          output: pdf
              ? "${args.path} is a PDF, which this model cannot read "
                    "directly. Read it with a command at that path instead, "
                    "such as `pdftotext`."
              : "${args.path} is an image, which this model cannot view. "
                    "A command can work with it at that path.",
        );
      }
      final limit = pdf ? pdfBudgetBytes : maxReadImageBytes;
      if (bytes.length > limit) {
        return ShellResult.failed(
          "${args.path} is ${formatSize(bytes.length)}, "
          "over the ${formatSize(limit)} a request can carry. "
          "${pdf ? "Split it" : "Downscale it"} with a command, then read the result.",
        );
      }
      attached = await turn.saved(
        LlmAttachment(filename: p.basename(path), mimeType: type, bytes: bytes),
      );
      return ShellResult(
        returnCode: 0,
        output: "${pdf ? "PDF" : "Image"} ${args.path} attached.",
      );
    }

    Future<ShellResult> run() async {
      final file = File(path);
      if (!file.existsSync()) {
        return ShellResult(
          returnCode: -1,
          output: "",
          exceptionInfo: "File not found: ${args.path}",
        );
      }
      final bytes = await file.readAsBytes();
      final type = readBlockTypeOf(bytes);
      if (type != null) return attach(type, bytes);
      String content;
      try {
        content = utf8.decode(bytes);
      } on FormatException {
        return ShellResult(
          returnCode: -1,
          output: "",
          exceptionInfo:
              "Not a UTF-8 text file (binary?): ${args.path}. "
              "Inspect binary files with a command instead of $readToolName.",
        );
      }
      final lines = content.split("\n");
      final offset = (args.offset ?? 1).clamp(1, lines.length + 1);
      final limit = args.limit ?? lines.length;
      final end = (offset + limit - 1).clamp(1, lines.length);
      final buf = StringBuffer();
      for (var i = offset; i <= end; i++) {
        buf.writeln("$i: ${lines[i - 1]}");
      }
      final result = buf.toString();
      await _stamp(turn, path);
      nested = turn.memory.nested
          ? [
              // An AGENTS.md read on purpose is already in front of the model.
              for (final file in await findNestedInstructions(
                path,
                alreadyLoaded: turn.loadedInstructions,
                excludes: turn.memory.excludes,
              ))
                if (file.path != path) file,
            ]
          : const <InstructionFile>[];
      final output = nested.isEmpty
          ? (result.isEmpty ? "(empty file)" : result)
          : "$result\n\n${renderInstructions(nested)}";
      return ShellResult(returnCode: 0, output: output);
    }

    final outcome = GateOutcome();
    yield* turn.gate.path(
      call,
      path,
      readToolName,
      run,
      outcome,
      granted: [
        ...(await turn.gate.permissions()).writableDirs,
        ?turn.attachmentsDir,
      ],
      ruleSubject: path,
    );
    // Between the call and its result, which is where the projection looks
    // for a tool's files.
    if (attached != null) yield attached!;
    yield ToolResultEvent(outcome.resultOf(call));
    // A successful read reports what it reached here, the claim deciding
    // which of the findings are this conversation's first.
    if (nested.isNotEmpty) {
      final claim = turn.claimInstruction;
      final fresh = [
        for (final file in nested)
          if (claim == null || claim(file.path)) file.ref,
      ];
      if (fresh.isNotEmpty) yield InstructionsReadEvent(fresh);
    }
  }
}

/// Write a file, creating or overwriting. The same gate as `read`.
class WriteTool extends AgentTool {
  WriteTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.files;

  @override
  String get name => writeToolName;

  @override
  String get description =>
      "Write a file to the workspace, creating or "
      "overwriting it. Paths are relative to the workspace; prefix with "
      "`project:` to write to the project workspace; an absolute path writes "
      "the machine directly, and the user is asked before it runs. The "
      "content is the full file — no append or merge. Use `edit` for partial "
      "changes to an existing file. An existing file must be read with `read` "
      "first, and read again if it has changed since.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "path": _pathArg,
      "content": {"type": "string", "description": "The full file content."},
    },
    "required": ["path", "content"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final args = writeArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* toolRejected(
        call,
        'The $writeToolName tool takes {"path": "...", "content": "..."}; '
        "those arguments were missing.",
      );
      return;
    }
    final path = turn.resolvePath(args.path);
    if (_inAttachments(turn, path)) {
      yield* toolRejected(call, _readOnlyAttachment(args.path));
      return;
    }
    // Asked before the gate too, so a refusal raises no banner first.
    if (await _unread(turn, path, args.path, writeToolName)
        case final problem?) {
      yield* toolRejected(call, problem);
      return;
    }
    yield toolCalled(call, args.path);
    yield* gatedFileRun(
      turn,
      call,
      path,
      writeToolName,
      ruleSubject: path,
      () async {
        if (await _unread(turn, path, args.path, writeToolName)
            case final problem?) {
          return ShellResult.failed(problem);
        }
        await Directory(p.dirname(path)).create(recursive: true);
        await File(path).writeAsString(args.content);
        await _stamp(turn, path);
        return ShellResult(
          returnCode: 0,
          output: "Wrote ${args.content.length} bytes to ${args.path}",
        );
      },
    );
  }
}

/// Edit a file by exact string replacement. The same gate as `read`.
class EditTool extends AgentTool {
  EditTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.files;

  @override
  String get name => editToolName;

  @override
  String get description =>
      "Edit a file by replacing `old_string` with "
      "`new_string`. The `old_string` must appear exactly once in the file, "
      "or set `replace_all` to replace every occurrence. Paths are relative "
      "to the workspace; prefix with `project:` to edit in the project "
      "workspace; an absolute path edits the machine directly, and the user "
      "is asked before it runs. Use `write` to create a new file or overwrite "
      "one entirely. The file must be read with `read` first, and read again "
      "if it has changed since.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "path": _pathArg,
      "old_string": {
        "type": "string",
        "description": "The exact string to find in the file.",
      },
      "new_string": {
        "type": "string",
        "description": "The string to replace it with.",
      },
      "replace_all": {
        "type": "boolean",
        "description":
            "Replace every occurrence of `old_string` instead "
            "of requiring it to be unique. Defaults to false.",
      },
    },
    "required": ["path", "old_string", "new_string"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final args = editArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* toolRejected(
        call,
        'The $editToolName tool takes {"path": "...", "old_string": "...", '
        '"new_string": "..."}; those arguments were missing.',
      );
      return;
    }
    final path = turn.resolvePath(args.path);
    if (_inAttachments(turn, path)) {
      yield* toolRejected(call, _readOnlyAttachment(args.path));
      return;
    }
    if (await _unread(turn, path, args.path, editToolName)
        case final problem?) {
      yield* toolRejected(call, problem);
      return;
    }
    yield toolCalled(call, args.path);
    yield* gatedFileRun(
      turn,
      call,
      path,
      editToolName,
      ruleSubject: path,
      () async {
        final file = File(path);
        if (!file.existsSync()) {
          return ShellResult(
            returnCode: -1,
            output: "",
            exceptionInfo: "File not found: ${args.path}",
          );
        }
        if (await _unread(turn, path, args.path, editToolName)
            case final problem?) {
          return ShellResult.failed(problem);
        }
        final content = await file.readAsString();
        final count = content.split(args.oldString).length - 1;
        if (count == 0) {
          return ShellResult(
            returnCode: -1,
            output: "",
            exceptionInfo: "old_string not found in ${args.path}",
          );
        }
        if (!args.replaceAll && count > 1) {
          return ShellResult(
            returnCode: -1,
            output: "",
            exceptionInfo:
                "old_string appears $count times in ${args.path}; "
                "add context to make it unique or set replace_all.",
          );
        }
        final updated = args.replaceAll
            ? content.replaceAll(args.oldString, args.newString)
            : content.replaceFirst(args.oldString, args.newString);
        await file.writeAsString(updated);
        await _stamp(turn, path);
        return ShellResult(
          returnCode: 0,
          output: "Edited ${args.path}: replaced $count occurrence(s).",
        );
      },
    );
  }
}

/// Copy an attachment out of the read-only `resources/` into the workspace, as
/// a file that can be changed. A tool rather than `cp` because the copy has
/// to come out writable, and a copy of a read-only file does not: read whole
/// and written new. Offered where the chat has attachments to copy.
class AttachmentSaveTool extends AgentTool {
  AttachmentSaveTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.files;

  @override
  String get name => attachmentSaveToolName;

  @override
  bool get offered => offer.attachments;

  @override
  String get description =>
      "Copy an attachment into the workspace so it can "
      "be changed. Attachments are read-only: change nothing at their paths, "
      "with this tool or any command. `path` is the attachment's path as the "
      "conversation gave it. The copy goes to `dest`, by default "
      "`attachments/<its name>` in the chat workspace, and is yours to edit.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The attachment's path, as the conversation gave it.",
      },
      "dest": {
        "type": "string",
        "description":
            "Where the copy goes: workspace-relative, or "
            "`project:` + path for the project workspace. Defaults to "
            "`attachments/<its name>`.",
      },
    },
    "required": ["path"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final source = stringArg(call.argumentsJson, "path");
    if (source == null) {
      yield* toolRejected(
        call,
        'The $attachmentSaveToolName tool takes {"path": "..."}; that '
        "argument was missing.",
      );
      return;
    }
    final from = turn.resolvePath(source);
    if (!_inAttachments(turn, from)) {
      yield* toolRejected(
        call,
        "$source is not an attachment. $attachmentSaveToolName copies "
        "the files attached to this chat; copy anything else with a "
        "command.",
      );
      return;
    }
    final name = attachmentFilename(p.basename(from));
    final dest =
        stringArg(call.argumentsJson, "dest") ?? p.join("attachments", name);
    final to = turn.resolvePath(dest);
    if (_inAttachments(turn, to)) {
      yield* toolRejected(call, _readOnlyAttachment(dest));
      return;
    }
    yield toolCalled(call, source);
    yield* gatedFileRun(turn, call, to, attachmentSaveToolName, () async {
      final file = File(from);
      if (!file.existsSync()) {
        return ShellResult.failed("File not found: $source");
      }
      if (File(to).existsSync()) {
        return ShellResult.failed(
          "$dest already exists. Pass another dest, or change that one.",
        );
      }
      await Directory(p.dirname(to)).create(recursive: true);
      await File(to).writeAsBytes(await file.readAsBytes());
      // Copied, so read as far as the edit tools are concerned: changing it
      // next needs no read of a file the model has not seen as text.
      await _stamp(turn, to);
      return ShellResult(
        returnCode: 0,
        output: "Copied $source to $dest, which you can change.",
      );
    });
  }
}
