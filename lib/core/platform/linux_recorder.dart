import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart" show Uint8List, visibleForTesting;
import "package:record_linux/record_linux.dart" show RecordLinux;
import "package:record/record.dart" show RecordConfig;

/// `record`'s Linux recorder with a `pw-record` fallback beside its
/// `parecord`: only `startStream` — the one call the app makes — is taken
/// over, the rest stays the stock implementation's. The why is "Hearing and
/// speaking" in `lib/data/voice/AGENTS.md`.
class LinuxRecorder extends RecordLinux {
  /// The environment the capture is looked up in. A field only so the test
  /// can point `PATH` at its own fake `pw-record` and drive the real spawn,
  /// stream and stop.
  @visibleForTesting
  Map<String, String> environment = Platform.environment;

  Process? _process;

  /// Where the named capture binary sits on `PATH`, as a path to run rather
  /// than a name: absolute, so the spawn does not depend on the search
  /// `Process.start` does — the machine's real `PATH`, not always the one
  /// the app was given. Null where it is not there.
  @visibleForTesting
  static String? locate(String bin, Map<String, String> environment) {
    for (final dir in (environment["PATH"] ?? "").split(":")) {
      if (dir.isEmpty) continue;
      final path = "$dir/$bin";
      if (File(path).existsSync()) return path;
    }
    return null;
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
    final parecord = locate("parecord", environment);
    if (parecord != null) return super.startStream(recorderId, config);
    final pwRecord = locate("pw-record", environment);
    if (pwRecord == null) {
      throw StateError(
        "voice capture needs parecord (pulseaudio-utils) "
        "or pw-record (pipewire-utils) on PATH.",
      );
    }
    await stop(recorderId);
    _process = await Process.start(pwRecord, pwRecordArgs(config));
    // An undrained stderr fills its pipe and blocks pw-record mid-capture.
    unawaited(_process!.stderr.drain<void>());
    return _process!.stdout.map((data) =>
        data is Uint8List ? data : Uint8List.fromList(data));
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