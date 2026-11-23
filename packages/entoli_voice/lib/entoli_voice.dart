import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:path/path.dart" as p;
import "package:record_platform_interface/record_platform_interface.dart"
    show RecordPlatform;
import "package:entoli_core/model/download.dart";
import "package:entoli_core/model/model_process.dart";
import "package:entoli_core/model/voice.dart";
import "package:entoli_core/model/voice_model_store.dart";

import "android_voice.dart";
import "file_voice_model_store.dart";
import "ios_voice.dart";
import "linux_recorder.dart";
import "macos_voice.dart";
import "sherpa_voice.dart";

export "sherpa_voice.dart" show sherpaWorkers;

/// Once per process, before anything records: Silero's licence, and on Linux
/// the recorder that falls back to pw-record, record's own being
/// parecord-only.
void registerVoice() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ["silero-vad"],
      await rootBundle.loadString(
        "packages/entoli_voice/assets/models/silero-vad-LICENSE.txt",
      ),
    );
  });
  if (Platform.isLinux) RecordPlatform.instance = LinuxRecorder();
}

/// The downloaded speech models, under `<cacheDir>/models`.
VoiceModelStore openVoiceModelStore(String cacheDir, StartDownload download) =>
    FileVoiceModelStore(p.join(cacheDir, "models"), download: download);

/// sherpa-onnx on the desktops; Android and macOS also have their system
/// engines (see [AndroidVoice], [MacosVoice]); iOS has Apple's alone (see
/// [IosVoice]). [process] is where sherpa's workers run.
Voice platformVoice(
  VoiceModelStore store,
  String cacheDir,
  ModelProcess process,
) {
  if (Platform.isAndroid) return AndroidVoice(store, cacheDir, process);
  if (Platform.isIOS) return const IosVoice();
  if (Platform.isMacOS) return MacosVoice(store, cacheDir, process);
  return SherpaVoice(store, cacheDir, process);
}
