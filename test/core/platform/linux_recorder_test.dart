import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:record/record.dart"
    show AudioEncoder, InputDevice, RecordConfig, RecordPlatform;

import "package:agent_chat/core/platform/linux_recorder.dart";
import "package:agent_chat/core/platform/host.dart"
    show registerRecorder;

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
    // A device goes across as --target, and the properties ride only where
    // the config asked for any.
    expect(
      LinuxRecorder.pwRecordArgs(config(device: "alsa_input.usb-mic")),
      containsAllInOrder(["--target=alsa_input.usb-mic", "-"]),
    );
    expect(
      LinuxRecorder.pwRecordArgs(const RecordConfig()),
      isNot(contains("-P")),
    );
  });

  group("locate", () {
    late Directory bin;

    setUp(() => bin = Directory.systemTemp.createTempSync("recorder-bin"));
    tearDown(() => bin.deleteSync(recursive: true));

    void put(String name) =>
        File("${bin.path}/$name").writeAsStringSync("#!/bin/sh\n");

    test("the first directory holding the binary wins", () {
      put("parecord");
      put("pw-record");
      expect(
        LinuxRecorder.locate("parecord", {"PATH": "/nowhere:${bin.path}"}),
        "${bin.path}/parecord",
      );
      expect(LinuxRecorder.locate("pw-record", {"PATH": bin.path}),
          "${bin.path}/pw-record");
      // Nothing found is null, an empty PATH included.
      expect(LinuxRecorder.locate("pw-cli", {"PATH": bin.path}), isNull);
      expect(LinuxRecorder.locate("pw-record", const {}), isNull);
    });
  });

  test("with neither binary, starting says which packages to install", () async {
    final recorder = LinuxRecorder()..environment = const {};
    await expectLater(
      recorder.startStream("test", config()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          "message",
          contains("pw-record (pipewire-utils)"),
        ),
      ),
    );
  });

  test("registerRecorder puts LinuxRecorder on RecordPlatform.instance",
      () {
    final before = RecordPlatform.instance;
    registerRecorder();
    expect(RecordPlatform.instance, isA<LinuxRecorder>());
    // Not left standing over the suite: another test in this file spawns
    // through the stock instance.
    RecordPlatform.instance = before;
  }, skip: Platform.isLinux
      ? null
      : "registerRecorder answers Linux alone, and leaves the stock "
          "platform implementation standing everywhere else");
}
