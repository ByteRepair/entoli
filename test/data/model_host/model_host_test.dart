import "dart:async";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/model_host/host_connection.dart";
import "package:agent_chat/data/model_host/host_frame.dart";
import "package:agent_chat/data/model_host/model_host.dart";
import "package:agent_chat/data/model_host/model_host_server.dart";
import "package:agent_chat/data/model_host/worker.dart";

import "../../harness.dart";

// The app's half and the host's half of the model host, wired over a real
// Unix socket in this process: what crosses is the real framing, and nothing
// is launched. The host's native half is a mock channel of the test's own.
//
// Plain `test`s, not `testWidgets`: sockets and isolates run on real time.

const native = MethodChannel("test/models");

/// Answers each message with what it was started with and what it was sent.
void _echo((SendPort, List<Object?>) init) async {
  final (reply, argument) = init;
  final port = ReceivePort();
  reply.send(port.sendPort);
  await for (final message in port) {
    if (message case ["close"]) break;
    reply.send(["echo", argument.first, message]);
  }
  port.close();
  reply.send(["closed"]);
}

const echo = WorkerKind("echo", _echo);

/// A host whose launches are counted, and whose current host end can be
/// dropped the way a crash would drop it.
class Launches {
  var count = 0;
  HostConnection? hostEnd;

  Future<HostConnection> launch() async {
    count++;
    final dir = tempDir("model_host_test_");
    final address = InternetAddress(
      "${dir.path}/s",
      type: InternetAddressType.unix,
    );
    final server = await ServerSocket.bind(address, 0);
    final hostSide = await Socket.connect(address, 0);
    final appSide = await server.first;
    await server.close();
    hostEnd = HostConnection(hostSide);
    ModelHostServer(hostEnd!, channels: [native], workers: [echo]);
    return HostConnection(appSide);
  }
}

Future<void> fromNative(String method, Object? arguments) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          native.name,
          native.codec.encodeMethodCall(MethodCall(method, arguments)),
          (_) {},
        );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Launches launches;
  late HelperModelHost host;

  setUp(() {
    launches = Launches();
    host = HelperModelHost(launches.launch);
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == "refuse") {
        throw PlatformException(code: "no", message: "refused");
      }
      return {"method": call.method, "arguments": call.arguments};
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    launches.hostEnd?.close();
  });

  group("frames", () {
    const codec = FrameCodec();

    Future<List<HostFrame>> decode(List<Uint8List> chunks) =>
        Stream.fromIterable(chunks).transform(codec.decoder).toList();

    test(
      "a frame split anywhere, or several to a chunk, decodes whole",
      () async {
        final frames = [
          const CallFrame(1, "c", "m", {"a": 1}),
          PostFrame(2, [
            "audio",
            Float32List.fromList([0.5, -0.25]),
          ]),
          const CloseFrame(2),
        ];
        final bytes = [
          for (final f in frames)
            for (final part in codec.encode(f)) ...part,
        ];

        for (final step in [1, 3, 7, bytes.length]) {
          final chunks = [
            for (var i = 0; i < bytes.length; i += step)
              Uint8List.fromList(
                bytes.sublist(i, (i + step).clamp(0, bytes.length)),
              ),
          ];
          final decoded = await decode(chunks);
          expect(decoded.map((f) => f.fields.first), ["call", "post", "close"]);
          final post = decoded[1] as PostFrame;
          expect((post.message as List)[1], [0.5, -0.25]);
        }
      },
    );

    test("a value that is no frame is refused", () {
      expect(() => HostFrame.decode(["nonsense"]), throwsFormatException);
    });
  });

  test("a call crosses and answers as a channel here would", () async {
    final channel = host.channel(native.name);

    expect(
      await channel.invokeMethod<Map<Object?, Object?>>("load", {"x": 1}),
      {
        "method": "load",
        "arguments": {"x": 1},
      },
    );
    await expectLater(
      channel.invokeMethod("refuse"),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, "code", "no")
            .having((e) => e.message, "message", "refused"),
      ),
    );
    expect(launches.count, 1, reason: "one host serves every call");
  });

  test("what the native half says unasked arrives as calls", () async {
    final channel = host.channel(native.name);
    final said = channel.calls.first;
    // The host starts on first use; a call is what starts it here.
    await channel.invokeMethod("handshake");

    await fromNative("text", {"id": "fm1", "text": "hi"});

    final call = await said.timeout(const Duration(seconds: 5));
    expect(call.method, "text");
    expect(call.arguments, {"id": "fm1", "text": "hi"});
  });

  test("a worker runs in the host by name", () async {
    final worker = await host.spawn(echo, ["started"]);
    final heard = worker.messages.first;

    worker.send(["speak", 7, "hello"]);

    expect(await heard.timeout(const Duration(seconds: 5)), [
      "echo",
      "started",
      ["speak", 7, "hello"],
    ]);
    worker.close();
  });

  test("a host that goes fails what waits on it, and the next ask starts "
      "another", () async {
    final channel = host.channel(native.name);
    await channel.invokeMethod("handshake");
    final worker = await host.spawn(echo, ["started"]);
    final workerSaid = <Object?>[];
    final workerErrors = <Object>[];
    final workerDone = Completer<void>();
    worker.messages.listen(
      workerSaid.add,
      onError: workerErrors.add,
      onDone: workerDone.complete,
    );
    final channelErrors = <Object>[];
    channel.calls.listen((_) {}, onError: channelErrors.add);
    final lost = host.lost.first;

    launches.hostEnd!.close();
    await lost.timeout(const Duration(seconds: 5));

    expect(channelErrors.single, isA<ModelHostGone>());
    await workerDone.future.timeout(const Duration(seconds: 5));
    expect(workerSaid, isEmpty);
    expect(workerErrors.single, isA<ModelHostGone>());

    expect(await channel.invokeMethod("load"), isNotNull);
    expect(launches.count, 2);
  });

  test("a worker the host cannot start ends in an error, not in the "
      "worker's words", () async {
    final worker = await host.spawn(
      const WorkerKind("unknown", _echo),
      const [],
    );
    final errors = <Object>[];
    final done = Completer<void>();
    worker.messages.listen((_) {}, onError: errors.add, onDone: done.complete);

    await done.future.timeout(const Duration(seconds: 5));
    expect(
      errors.single,
      isA<WorkerFailed>().having(
        (e) => e.message,
        "message",
        contains("unknown"),
      ),
    );
  });

  group("held and idle", () {
    const idle = Duration(milliseconds: 50);
    setUp(() => host = HelperModelHost(launches.launch, idle: idle));

    test("nothing held for the wait lets it go, and is no loss", () async {
      final lease = host.hold();
      await host.channel(native.name).invokeMethod("load");
      final hostEnd = launches.hostEnd!;
      var lost = false;
      host.lost.listen((_) => lost = true);

      lease.release();
      await hostEnd.done.timeout(const Duration(seconds: 5));

      // Nothing was in it: the app was not told it lost anything.
      expect(lost, isFalse);
      // The next ask starts another.
      host.hold();
      await host.channel(native.name).invokeMethod("load");
      expect(launches.count, 2);
    });

    test("held again within the wait, it stays", () async {
      final first = host.hold();
      await host.channel(native.name).invokeMethod("load");

      // A model switch: the next lease is taken before the last is given up.
      final second = host.hold();
      first.release();
      await Future<void>.delayed(idle * 4);

      await host.channel(native.name).invokeMethod("load");
      expect(launches.count, 1);
      second.release();
    });

    test("a running worker holds it, and its end lets it go", () async {
      final worker = await host.spawn(echo, ["started"]);
      final hostEnd = launches.hostEnd!;
      await Future<void>.delayed(idle * 4);
      expect(launches.count, 1);

      worker.close();
      await hostEnd.done.timeout(const Duration(seconds: 5));
    });
  });

  test("its footprint is asked of a running host, and none is started to "
      "answer", () async {
    messenger.setMockMethodCallHandler(
      modelHostChannel,
      (call) async => call.method == "footprint" ? 4096 : null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(modelHostChannel, null),
    );

    expect(await host.footprint(), isNull);
    expect(launches.count, 0);

    await host.channel(native.name).invokeMethod("load");
    expect(await host.footprint(), 4096);
  });
}
