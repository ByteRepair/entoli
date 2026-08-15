import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/attachment_picker.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

/// Two providers, two models each, deliberately not in alphabetical order so
/// tests can assert the UI sorts them.
const testModels = [
  ModelOption(providerId: "ollama-cloud", modelId: "llama-3", label: "Llama 3"),
  ModelOption(providerId: "ollama-cloud", modelId: "qwen-2.5", label: "Qwen 2.5"),
  ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4", label: "Claude Sonnet 4"),
  ModelOption(providerId: "anthropic", modelId: "claude-haiku-3", label: "Claude Haiku 3"),
];

/// A library whose commands include two names sharing a prefix, so tests can
/// assert the menu filters, and whose entries are deliberately out of order.
PromptLibrary testLibrary() => PromptLibrary([
      _doc(CompletionKind.command, "review", "review changes"),
      _doc(CompletionKind.command, "revert", "undo the last turn"),
      _doc(CompletionKind.command, "init", "guided AGENTS.md setup"),
      _doc(CompletionKind.agent, "explore", "fast codebase search"),
      _doc(CompletionKind.agent, "build", "the default agent"),
    ]);

PromptDocument _doc(CompletionKind kind, String name, String description) =>
    PromptDocument.parse(kind, name, "---\ndescription: $description\n---\n\nDo $name.\n");

/// A real 1x1 PNG: the chip decodes what it is given, so a stand-in string of
/// bytes would fail the codec rather than render.
final onePixelPng = base64Decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==");

/// An attachment with recognisable bytes, so a test can follow the same file
/// from the composer to the backend and back off disk.
Attachment testAttachment(
  String filename, {
  String mimeType = "text/plain",
  List<int> bytes = const [104, 105],
}) =>
    Attachment(filename: filename, mimeType: mimeType, bytes: Uint8List.fromList(bytes));

/// Stands in for the platform's file chooser, which no test can drive.
class FakeAttachmentPicker implements AttachmentPicker {
  final List<AttachmentKind> picks = [];

  /// What the next pick returns. Empty is a cancelled dialog.
  List<Attachment> scripted = const [];

  @override
  Future<List<Attachment>> pick(AttachmentKind kind) async {
    picks.add(kind);
    return scripted;
  }
}

class FakeBackend implements AgentBackend {
  var _created = 0;

  @override
  Future<Chat> createChat({String? title}) async {
    final now = DateTime.now();
    return Chat(
      state: ChatState(
        id: "fake-${++_created}",
        title: title ?? "New chat",
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  final List<({String prompt, String model, String provider})> questions = [];

  /// What `ask` answers. Null is a model that could not answer.
  String? scriptedAnswer;

  @override
  Future<String?> ask(String prompt,
      {required String model, required String provider}) async {
    questions.add((prompt: prompt, model: model, provider: provider));
    return scriptedAnswer;
  }

  final List<
      ({
        String text,
        String? model,
        String? provider,
        List<Attachment> attachments,
        bool approveCommands
      })> prompts = [];

  /// What the next turn streams back. Defaults to an immediate, empty reply.
  List<AgentEvent> scriptedEvents = const [DoneEvent()];

  /// When set, the turn stays open after the scripted events, the way a real
  /// one does while the backend is still working.
  Completer<void>? hold;

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [],
      String? model,
      String? provider,
      bool approveCommands = true}) async* {
    prompts.add((
      text: text,
      model: model,
      provider: provider,
      attachments: attachments,
      approveCommands: approveCommands,
    ));
    yield* Stream.fromIterable(scriptedEvents);
    if (hold != null) await hold!.future;
  }

  final List<List<Message>> resets = [];

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {
    resets.add(history);
  }

  var didShutdown = false;

  @override
  Future<void> shutdown() async => didShutdown = true;

  /// Long enough that a test only meets it by shortening it on purpose.
  @override
  Duration stallTimeout = const Duration(minutes: 5);

  final List<String> aborted = [];

  @override
  Future<void> abort(String chatId) async {
    aborted.add(chatId);
  }

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) async {}

  final List<({String requestId, List<String?> answers})> answered = [];

  @override
  Future<void> respondQuestions(
      String chatId, String requestId, List<String?> answers) async {
    answered.add((requestId: requestId, answers: answers));
  }

  @override
  Future<void> disposeChat(String chatId) async {}

  List<ModelOption> modelList = testModels;

  @override
  Future<List<ModelOption>> models() async => modelList;
}
