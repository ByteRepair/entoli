import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:record/record.dart" show AudioEncoder, InputDevice, RecordConfig;

import "package:agent_chat/core/platform/io/linux_recorder.dart";

/// The config the voice session sends: raw mono 16 kHz PCM with the two
/// noise properties on. The argv for it is pinned, and the device variant
/// beside it, since `--target` is the one flag only a config with a device
/// on it can show.
RecordConfig config({String? device}) => RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      device: device == null ? null : InputDevice(id: device, label: device),
    );

void main() {
  test("pw-record's argv is the stock parecord invocation translated", () {
    expect(
      LinuxRecorder.pwRecordArgs(config()),
      [
        "--raw",
        "--format=s16",
        "--rate=16000",
        "--channels=1",
        "--latency=100ms",
        "-P",
        "echo_cancellation=1,noise_suppression=1",
        "-",
      ],
    );
  });

  test("a device goes across as --target, properties only where asked", () {
    expect(
      LinuxRecorder.pwRecordArgs(config(device: "alsa_input.usb-mic")),
      containsAllInOrder(["--target=alsa_input.usb-mic", "-"]),
    );
    expect(
      LinuxRecorder.pwRecordArgs(const RecordConfig()),
      isNot(contains("-P")),
    );
  });

  group("findCapture", () {
    late Directory bin;

    setUp(() => bin = Directory.systemTemp.createTempSync("recorder-bin"));
    tearDown(() => bin.deleteSync(recursive: true));

    void put(String name) =>
        File("${bin.path}/$name").writeAsStringSync("#!/bin/sh\n");

    test("parecord preferred where both are there", () {
      put("parecord");
      put("pw-record");
      expect(
        LinuxRecorder.findCapture({"PATH": "/nowhere:${bin.path}"}),
        "${bin.path}/parecord",
      );
    });

    test("pw-record stands in where parecord is missing", () {
      put("pw-record");
      expect(
        LinuxRecorder.findCapture({"PATH": bin.path}),
        "${bin.path}/pw-record",
      );
    });

    test("neither is a message naming both packages, not a ProcessException",
        () {
      expect(
        () => LinuxRecorder.findCapture({"PATH": bin.path}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            "message",
            contains("pw-record (pipewire-utils)"),
          ),
        ),
      );
      expect(
        () => LinuxRecorder.findCapture(const {}),
        throwsA(isA<StateError>()),
      );
    });
  });

  test("a session streams what pw-record writes and stops it", () async {
    final bin = Directory.systemTemp.createTempSync("recorder-bin");
    addTearDown(() => bin.deleteSync(recursive: true));
    // A stand-in that writes a header, then some bytes, then keeps the pipe
    // open — the shape of a capture nobody has spoken into yet.
    File("${bin.path}/pw-record").writeAsStringSync(
      "#!/bin/sh\ncat /dev/null; printf '\\x01\\x02\\x03\\x04'; sleep 30\n",
    );
    Process.runSync("chmod", ["+x", "${bin.path}/pw-record"]);

    final recorder = LinuxRecorder()..environment = {"PATH": bin.path};
    addTearDown(() => recorder.dispose("test"));

    final stream = await recorder.startStream("test", config());
    final chunks = await stream.take(1).toList();
    expect(chunks.single, [1, 2, 3, 4]);

    // Stopping closes the stream and the process with it, which is what
    // the session's shut-microphone path relies on.
    await recorder.stop("test");
    expect(recorder.environment["PATH"], bin.path);
  });
}