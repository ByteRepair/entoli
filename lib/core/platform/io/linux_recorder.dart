import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart" show Uint8List;
import "package:record_linux/record_linux.dart" show RecordLinux;
import "package:record/record.dart" show RecordConfig;

/// The recorder the voice session's microphone runs on: `record`'s own Linux
/// implementation with one thing changed.
///
/// That implementation shells out to `parecord` (`pulseaudio-utils`) and to
/// nothing else, so a PipeWire machine — most of them now, Fedora included,
/// which ships `pipewire-utils` and not `pulseaudio-utils` — got a voice
/// session that died on a `ProcessException` the first time it asked to hear
/// anything. This finds `parecord` on `PATH` and, where it is missing,
/// `pw-record`; the stock implementation runs where the first is found, and
/// the capture is [pwRecordArgs]' translation where it is not. Neither there:
/// a message naming the two packages instead of the bare `ProcessException`,
/// which is what voice mode reports.
///
/// Only `startStream` — the one call the app makes — is taken over; every
/// other member, recording to a file and `pactl`'s device listing among
/// them, is the stock implementation's and stays `parecord`-shaped.
class LinuxRecorder extends RecordLinux {
  /// Read per start. A field only so the test can point `PATH` at its own
  /// fake `pw-record` and drive the real spawn, stream and stop.
  Map<String, String> environment = Platform.environment;

  Process? _process;

  /// The capture binary on `PATH`, as a path to run rather than a name:
  /// `parecord` preferred, the first directory holding it wins. Absolute, so
  /// the spawn does not depend on the search `Process.start` does — which is
  /// the machine's real `PATH`, not always the one the app was given. A
  /// [StateError] naming both packages where there is neither, which is what
  /// voice mode reports.
  static String findCapture(Map<String, String> environment) {
    final dirs = (environment["PATH"] ?? "")
        .split(":")
        .where((dir) => dir.isNotEmpty);
    for (final bin in const ["parecord", "pw-record"]) {
      for (final dir in dirs) {
        final path = "$dir/$bin";
        if (File(path).existsSync()) return path;
      }
    }
    throw StateError(
      "voice capture needs parecord (pulseaudio-utils) "
      "or pw-record (pipewire-utils) on PATH.",
    );
  }

  /// `pw-record`'s answer to what the stock implementation asks `parecord`:
  /// raw s16 PCM at the config's rate and width, a 100 ms latency, and the
  /// noise and echo properties `parecord` would have been given. Ends with
  /// `-`, capture to stdout. `pw-record` names its format without the
  /// endianness (`s16` rather than `s16le`, little-endian being the only
  /// thing a capture has), its latency with a unit, and its properties as
  /// one comma-separated `-P`.
  static List<String> pwRecordArgs(RecordConfig config) {
    final properties = [
      if (config.autoGain) "auto_gain_control=1",
      if (config.echoCancel) "echo_cancellation=1",
      if (config.noiseSuppress) "noise_suppression=1",
    ];
    return [
      "--raw",
      "--format=s16",
      "--rate=${config.sampleRate}",
      "--channels=${config.numChannels}",
      "--latency=100ms",
      if (config.device != null) "--target=${config.device!.id}",
      if (properties.isNotEmpty) ...["-P", properties.join(",")],
      "-",
    ];
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    final capture = findCapture(environment);
    if (capture.endsWith("pw-record")) {
      await stop(recorderId);
      _process = await Process.start(capture, pwRecordArgs(config));
      return _process!.stdout.map(Uint8List.fromList);
    }
    return super.startStream(recorderId, config);
  }

  @override
  Future<String?> stop(String recorderId) async {
    // This class's own pw-record, where one is running. The stock stop answers
    // for its parecord process and resets its own state, neither of which
    // this path touches.
    _process?.kill();
    _process = null;
    return super.stop(recorderId);
  }
}