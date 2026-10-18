import AVFoundation
import Flutter
import Speech

/// The iOS half of the `agent_chat/voice` channel — the same contract
/// `VoiceChannel.kt` answers on Android, because the Dart `Native*` strategies
/// are what drive it from either platform. Recognition is Apple's and
/// on-device only, so nothing said leaves the device; the languages answer is
/// what enforces that, since a locale the device cannot hear on-device is
/// never offered.
///
/// The grants are asked at the first listening turn, never at the probe: a
/// permission sheet nobody was pressing a button for is worse than one at the
/// Talk button. A refusal arrives as a recognition error, which the voice
/// screen shows; it is not remembered here, and the next launch re-probes.
class VoiceChannel: NSObject {
  private static var instance: VoiceChannel?

  static func register(with bridge: FlutterImplicitEngineBridge) {
    guard let registrar = bridge.pluginRegistry.registrar(forPlugin: "VoiceChannel") else {
      return
    }
    instance = VoiceChannel(messenger: registrar.messenger())
  }

  private let channel: FlutterMethodChannel
  private let synthesizer = AVSpeechSynthesizer()
  private let engine = AVAudioEngine()

  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var wantListening = false

  // Endpointing: what says the person has stopped is the level. The Android
  // channel learns it from the transcription stilling; the level is the
  // shortcut here, self-calibrated against the loudest thing said so far.
  // shortcut: level-based, so a noisy room may cut speech — the Touch-to-speak
  // toggle is the answer, and the transcription rule is the upgrade.
  private var peak: Float = -90
  private var quietSince: Double?
  private var endpointTimer: Timer?
  private var hasPartial = false

  private var languages: [[String: String]]?
  private var pendingUtterances: [ObjectIdentifier: Int] = [:]
  private var voice: AVSpeechSynthesisVoice?
  private var interruptionObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agent_chat/voice", binaryMessenger: messenger)
    super.init()
    synthesizer.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      // Only the beginning is the event; the ended phase answers it. An
      // interruption leaves the engine idle either way, so what was queued is
      // cancelled here to drain the pending count rather than held for a
      // microphone state that is no longer coming.
      guard let self,
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began
      else { return }
      self.synthesizer.stopSpeaking(at: .immediate)
      guard self.wantListening else { return }
      self.send("recognitionError", "The microphone was interrupted.")
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "engines":
      let status = SFSpeechRecognizer.authorizationStatus()
      result([
        "recognition": status != .denied && status != .restricted,
        "speech": !AVSpeechSynthesisVoice.speechVoices().isEmpty,
      ])
    case "languages":
      computeLanguages { result($0) }
    case "setRecognitionListening":
      let args = call.arguments as? [String: Any] ?? [:]
      setListening(on: args["on"] as? Bool ?? false,
                   finish: args["finish"] as? Bool ?? false,
                   language: args["language"] as? String)
      result(nil)
    case "stopRecognition":
      stopRecognizing()
      result(nil)
    case "initSpeech":
      let args = call.arguments as? [String: Any] ?? [:]
      voice = (args["language"] as? String).flatMap { AVSpeechSynthesisVoice(language: $0) }
      send("speechReady", nil)
      result(nil)
    case "speak":
      let args = call.arguments as? [String: Any] ?? [:]
      speak(args["text"] as? String ?? "", generation: args["generation"] as? Int ?? 0)
      result(nil)
    case "stopSpeech":
      pendingUtterances.removeAll()
      synthesizer.stopSpeaking(at: .immediate)
      result(nil)
    case "disposeSpeech":
      synthesizer.stopSpeaking(at: .immediate)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Everything Dart hears goes through here: a `MethodChannel` may be
  /// touched from the platform thread only, and callers — the audio tap, the
  /// speech delegate — are not always on it. Where one already is, no hop.
  private func send(_ method: String, _ arguments: Any? = nil) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod(method, arguments: arguments)
      }
      return
    }
    channel.invokeMethod(method, arguments: arguments)
  }

  /// What both halves can hear and say on-device, which is the intersection of
  /// what the Speech framework can do without a server and what the system can
  /// speak. Asked off the platform thread — the sweep is one recognizer
  /// construction per supported locale and this thread is the settings
  /// page's — answered once; the next launch asks again, the answer moving
  /// with OS model packs.
  private func computeLanguages(_ answer: @escaping ([[String: String]]) -> Void) {
    if let languages {
      answer(languages)
      return
    }
    DispatchQueue.global().async { [weak self] in
      var heard: Set<String> = []
      for locale in SFSpeechRecognizer.supportedLocales() {
        if let recognizer = SFSpeechRecognizer(locale: locale),
           recognizer.supportsOnDeviceRecognition {
          heard.insert(locale.identifier)
        }
      }
      let spoken = Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
      let computed = heard.intersection(spoken).sorted().map {
        ["tag": $0, "name": Locale.current.localizedString(forIdentifier: $0) ?? $0]
      }
      DispatchQueue.main.async {
        self?.languages = computed
        answer(computed)
      }
    }
  }

  private func setListening(on: Bool, finish: Bool, language: String?) {
    if on {
      wantListening = true
      startRecognizing(language: language)
    } else {
      wantListening = false
      endpointTimer?.invalidate()
      if finish {
        // The user saying they have finished talking: end the request and let
        // the final deliver what was said — with no partial arrived yet,
        // ending still answers the nothing it heard where a cancellation
        // carries it away. recognizing then tears itself down, wantListening
        // being false.
        request?.endAudio()
      } else {
        stopRecognizing()
      }
    }
  }

  private func startRecognizing(language: String?) {
    ensureGrants { [weak self] granted in
      guard let self else { return }
      guard granted else {
        self.send("recognitionError",
                  "Voice needs the microphone and speech-recognition "
                    + "permissions, in Settings → Privacy & Security.")
        self.stopRecognizing()
        return
      }
      self.recognize(language: language)
    }
  }

  private func recognize(language: String?) {
    teardownRecognition()

    let locale = (language?.isEmpty ?? true) ? nil : Locale(identifier: language!)
    let forLocale = locale.map { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
    guard let recognizer = forLocale, recognizer.isAvailable else {
      send("recognitionError", "Speech recognition is not available.")
      return
    }
    log("recognizing in \(locale?.identifier ?? recognizer.locale.identifier), "
        + "on-device supported: \(recognizer.supportsOnDeviceRecognition)")
#if !targetEnvironment(simulator)
    guard recognizer.supportsOnDeviceRecognition else {
      send("recognitionError", "This device cannot hear that language on-device.")
      return
    }
#endif

    do {
      let session = AVAudioSession.sharedInstance()
      // playAndRecord routes output to the earpiece unless told otherwise,
      // and the replies spoken between turns would come out there.
      try session.setCategory(
        .playAndRecord, mode: .measurement,
        options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      send("recognitionError", "The microphone could not be opened.")
      return
    }

    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    // On-device only, in every build: the network rung Android walks is
    // deliberately absent, and the languages answer is what keeps an
    // unsupported locale from here. The simulator has no carve-out for this
    // flag — it ships no dictation assets at all, so the recognizer fails to
    // initialize there in any mode (`kLSRErrorDomain` 300); the voice hand-run
    // is a real device's.
    newRequest.requiresOnDeviceRecognition = true
    request = newRequest
    self.recognizer = recognizer
    hasPartial = false
    peak = -90
    quietSince = nil

    // One utterance per request: the level says when it ended, the final
    // result delivers what it heard, and a still-listening session starts the
    // next request right there. Silence produces no callbacks at all on iOS,
    // so there is nothing to restart on but the endpoint timer.
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
      [weak self] buffer, _ in
      // The local, not the field: the tap runs on the engine's queue while
      // main may already be starting the next request's, and a request alive
      // beyond its own tap dies with the tap's removal.
      newRequest.append(buffer)
      self?.tapped(buffer)
    }
    do {
      try engine.start()
    } catch {
      stopRecognizing()
      send("recognitionError", "The microphone could not be opened.")
      return
    }

    var live: SFSpeechRecognitionTask?
    live = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
      DispatchQueue.main.async { self?.taskCallback(live, result, error) }
    }
    task = live
    armEndpointTimer()
  }

  private func taskCallback(
    _ live: SFSpeechRecognitionTask?, _ result: SFSpeechRecognitionResult?, _ error: Error?
  ) {
    // Identity, not a flag: the task whose callback this is must still be the
    // live one — the same check the tap puts its buffer through — since a
    // cancelled task's last callback can land after the next request started.
    guard let live, live === task else { return }
    if let result {
      hasPartial = true
      log("transcription \(result.isFinal ? "final" : "partial"): "
          + "\(result.bestTranscription.formattedString.count) chars")
      if result.isFinal {
        hear(result.bestTranscription.formattedString)
        if wantListening {
          // Posted rather than called where it happens: tearing the task down
          // inside its own callback is the shape Android's
          // ERROR_RECOGNIZER_BUSY came from.
          let language = recognizer?.locale.identifier
          DispatchQueue.main.async { self.recognize(language: language) }
        } else {
          stopRecognizing()
        }
      }
      return
    }
    guard let error else { return }
    log("recognition task failed: \(error.localizedDescription)")
    stopRecognizing()
    send("recognitionError", error.localizedDescription)
  }

  private func tapped(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData?[0] else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    var sum: Float = 0
    for i in 0..<frames {
      sum += channelData[i] * channelData[i]
    }
    let db = max(-90, 10 * log10(sum / Float(frames)))
    DispatchQueue.main.async { [weak self] in
      guard let self, self.wantListening else { return }
      self.send("rms", db)
      if db > self.peak - 12 && db > -45 {
        self.peak = max(self.peak, db)
        self.quietSince = nil
      } else if self.quietSince == nil {
        self.quietSince = CACurrentMediaTime()
      }
    }
  }

  private func armEndpointTimer() {
    endpointTimer?.invalidate()
    endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self, self.wantListening, self.hasPartial, let quiet = self.quietSince else { return }
      if CACurrentMediaTime() - quiet > 0.9 {
        log("ending the utterance: \(CACurrentMediaTime() - quiet)s of level quiet")
        self.quietSince = nil
        self.request?.endAudio()
      }
    }
  }

  /// The voice module's volume rule: chatter rides the channel to Dart's
  /// voiceLog in debug builds, and never prints here — the flutter console
  /// does not carry os_log.
  private func log(_ what: String) {
#if DEBUG
    send("voiceDebug", what)
#endif
  }

  private func hear(_ text: String) {
    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else { return }
    send("heard", spoken)
  }

  private func ensureGrants(_ done: @escaping (Bool) -> Void) {
    func afterSpeech(_ granted: Bool) {
      guard granted else { done(false); return }
      // Both callbacks land on an arbitrary queue; `done` touches the engine.
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { mic in
          DispatchQueue.main.async { done(mic) }
        }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { mic in
          DispatchQueue.main.async { done(mic) }
        }
      }
    }
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async { afterSpeech(status == .authorized) }
      }
    } else {
      afterSpeech(SFSpeechRecognizer.authorizationStatus() == .authorized)
    }
  }

  private func teardownRecognition() {
    endpointTimer?.invalidate()
    task?.cancel()
    task = nil
    request = nil
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
  }

  private func stopRecognizing() {
    wantListening = false
    teardownRecognition()
    if !synthesizer.isSpeaking {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func speak(_ text: String, generation: Int) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    pendingUtterances[ObjectIdentifier(utterance)] = generation
    // The reply can begin seconds after the microphone was shut, which
    // deactivated the session; whether the synthesiser re-activates one that
    // was explicitly released is version-dependent, and this is a no-op when
    // it was never down.
    try? AVAudioSession.sharedInstance().setActive(true)
    synthesizer.speak(utterance)
  }
}

extension VoiceChannel: AVSpeechSynthesizerDelegate {
  // A cancelled utterance was never heard, but the pending count on the Dart
  // side is what keeps silence reporting honest, and a stop there has already
  // zeroed it — the generation check is what makes the stale one land wrong.
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    speechDone(utterance)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    speechDone(utterance)
  }

  private func speechDone(_ utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    guard let generation = pendingUtterances[id] else { return }
    pendingUtterances[id] = nil
    send("speechDone", generation)
  }
}