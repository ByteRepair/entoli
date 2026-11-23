import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:entoli_chat/app/transcript/activity.dart" show LiveMessage;
import "package:entoli_chat/core/config.dart";
import "package:entoli_chat/core/migrations.dart";
import "package:entoli_chat/data/chat_share.dart";
import "package:entoli_chat/data/local/file_chat_store.dart";
import "package:entoli_chat/domain/chat_log.dart";
import "package:entoli_chat/domain/chat_share.dart";
import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/domain/plan.dart";
import "package:entoli_chat/domain/shell_job.dart";
import "package:archive/archive.dart";
import "package:entoli_share_viewer/memory_io.dart";
import "package:entoli_share_viewer/shared_chat_host.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// Where the sharer's data is, in memory: nothing here is on the disk.
const _sharer = "/sharer";
const _viewer = "/entoli";

const _job = ShellJob(id: 1, callId: "b1", command: "make", logPath: "/x");

Message _said(String id, MessageRole role, String text) => Message(
  id: id,
  role: role,
  createdAt: DateTime.utc(2026, 1, 1),
  author: role == MessageRole.assistant ? "@athena" : null,
  addressees: role == MessageRole.user ? const ["@athena"] : const [],
  parts: [MessagePart.text(text: text)],
);

void _put(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

/// A chat with a reply, an attachment, a plan, a sub-agent and a file, shared
/// with its workspace.
Future<Uint8List> _shared() async {
  final config = AppConfig.forDirectory(_sharer);
  final store = FileChatStore(config);
  await store.saveState(
    ChatState(
      id: "c1",
      title: "A shared chat",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
    ),
  );
  await store.append("c1", [
    ...recordsOf([
      _said("m1", MessageRole.user, "hello"),
      _said("m2", MessageRole.assistant, "hi there"),
    ]),
    const ChatRecord.turnEnd(messageId: "m2", reason: TurnEnd.done),
  ]);
  _put(p.join(config.resourcesDir("c1"), "photo.png"), [1, 2, 3]);
  _put(
    config.subAgentFile("c1", "call1"),
    utf8.encode(
      encodeLog(recordsOf([_said("s1", MessageRole.assistant, "sub done")])),
    ),
  );
  _put(
    p.join(config.workspaceDir("c1"), planFileName),
    utf8.encode("- [x] read the code\n- [ ] add parser\n"),
  );
  _put(p.join(config.workspaceDir("c1"), "notes.md"), utf8.encode("notes"));
  final link = await ChatShareSource(config, "c1").pack({
    ShareSection.attachments: {"photo.png"},
    ShareSection.workspace: {planFileName, "notes.md"},
  });
  return shareZipOf(Uri.parse(link!).fragment)!;
}

/// [listenable] once it has a value.
Future<T> _settled<T>(
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> listenable,
) {
  final done = Completer<T>();
  final sub = container.listen(listenable, (_, next) {
    if (next.hasValue && !done.isCompleted) done.complete(next.value as T);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

void main() {
  setUp(useMemoryFileSystem);
  tearDown(() => IOOverrides.global = null);

  group("in memory", () {
    test("a shared chat unpacks and reads with nothing on the disk", () async {
      final (:config, :chatId) = (await unpackShare(await _shared(), _viewer))!;
      final chat = await FileChatStore(config).load(chatId);

      expect(chat.state.title, "A shared chat");
      expect(chat.state.imported, isTrue);
      expect(chat.messages.map((m) => m.id), ["m1", "m2"]);
      IOOverrides.global = null;
      expect(Directory(_sharer).existsSync(), isFalse);
      expect(Directory(_viewer).existsSync(), isFalse);
    });

    test("a link from an older build runs the migration chain", () async {
      final zip = ZipDecoder().decodeBytes(await _shared());
      final older = Archive();
      for (final file in zip) {
        older.add(
          file.name == "version"
              ? ArchiveFile.string("version", migrations.first.version)
              : file,
        );
      }

      final unpacked = await unpackShare(
        ZipEncoder().encodeBytes(older),
        _viewer,
      );

      expect(unpacked?.chatId, "c1");
      expect(
        File(migrationStamp(_viewer)).readAsStringSync(),
        migrations.last.version,
      );
    });
  });

  group("the host", () {
    late ProviderContainer container;
    late SharedChatHost host;

    setUp(() async {
      final config = (await unpackShare(await _shared(), _viewer))!.config;
      final store = FileChatStore(config);
      host = SharedChatHost(
        await store.load("c1"),
        store: store,
        config: config,
      );
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test("views the chat it was made with, at rest", () {
      final view = container.read(host.view("c1"));

      expect(view.chat!.messages.map((m) => m.id), ["m1", "m2"]);
    });

    test("reads the plan out of the shared workspace", () async {
      final plan = await _settled(container, host.plan("c1"));

      expect(plan!.expand((s) => s.tasks).map((t) => t.text), [
        "read the code",
        "add parser",
      ]);
    });

    test("reads an attachment out of the chat", () async {
      final bytes = await _settled(container, host.resource("c1", "photo.png"));

      expect(bytes, [1, 2, 3]);
    });

    test("replays a sub-agent's transcript, ended", () async {
      final call = (chatId: "c1", callId: "call1");
      final done = Completer<LiveMessage>();
      final sub = container.listen(host.subAgent(call), (_, next) {
        if (next.message != null && !done.isCompleted) done.complete(next);
      }, fireImmediately: true);
      addTearDown(sub.close);

      final live = await done.future;

      expect(live.message!.id, "s1");
      expect(live.running, isFalse);
    });

    test("has no faces and no job logs", () {
      expect(container.read(host.face(name: "@athena")).value, isNull);
      expect(container.read(host.jobLog("c1", _job)).value, "");
    });

    test("puts the workspace where it was unpacked", () {
      expect(
        File(p.join(host.workspaceDir("c1"), "notes.md")).readAsStringSync(),
        "notes",
      );
    });
  });
}
