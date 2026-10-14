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
  private var stopping = false

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
    ) { [weak self] _ in
      // An interruption leaves the engine dead either way, and silence on a
      // listening session reads as a broken microphone — the session fails
      // loudly instead. Speech still queued was cancelled by the system, and
      // the cancellations drain the pending count on their own.
      guard let self, self.wantListening else { return }
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
      computeLanguages()
      result(languages)
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

  private func send(_ method: String, _ arguments: Any? = nil) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(method, arguments: arguments)
    }
  }

  // What both halves can hear and say on-device, which is the intersection of
  // what the Speech framework can do without a server and what the system can
  // speak. Computed once: the answer moves with OS model packs, and the next
  // launch asks again.
  private func computeLanguages() {
    if languages != nil { return }
    var heard: Set<String> = []
    for locale in SFSpeechRecognizer.supportedLocales() {
      if let recognizer = SFSpeechRecognizer(locale: locale),
         recognizer.supportsOnDeviceRecognition {
        heard.insert(locale.identifier)
      }
    }
    let spoken = Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
    languages = heard.intersection(spoken).sorted().map {
      ["tag": $0, "name": Locale.current.localizedString(forIdentifier: $0) ?? $0]
    }
  }

  private func setListening(on: Bool, finish: Bool, language: String?) {
    if on {
      wantListening = true
      startRecognizing(language: language)
    } else {
      wantListening = false
      endpointTimer?.invalidate()
      if finish, hasPartial {
        // The user saying they have finished talking: end the request and let
        // the final result deliver what was said; recognizing then tears
        // itself down, wantListening being false.
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
    stopping = false
    teardownRecognition()

    let locale = (language?.isEmpty ?? true) ? nil : Locale(identifier: language!)
    let forLocale = locale.map { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
    guard let recognizer = forLocale, recognizer.isAvailable else {
      send("recognitionError", "Speech recognition is not available.")
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      send("recognitionError", "This device cannot hear that language on-device.")
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
      try session.setActive(true)
    } catch {
      send("recognitionError", "The microphone could not be opened.")
      return
    }

    let newRequest = SFSpeechAudioBufferRecognitionRequest()
    newRequest.shouldReportPartialResults = true
    // On-device only: the network rung Android walks is deliberately absent,
    // and the languages answer is what keeps an unsupported locale from here.
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
      self?.tapped(buffer)
    }
    do {
      try engine.start()
    } catch {
      stopRecognizing()
      send("recognitionError", "The microphone could not be opened.")
      return
    }

    task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
      DispatchQueue.main.async { self?.taskCallback(result, error) }
    }
    armEndpointTimer()
  }

  private func taskCallback(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
    guard !stopping else { return }
    if let result {
      hasPartial = true
      if result.isFinal {
        hear(result.bestTranscription.formattedString)
        if wantListening {
          recognize(language: recognizer?.locale.identifier)
        } else {
          stopRecognizing()
        }
      }
      return
    }
    guard let error else { return }
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
        self.quietSince = nil
        self.request?.endAudio()
      }
    }
  }

  private func hear(_ text: String) {
    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else { return }
    send("heard", spoken)
  }

  private func ensureGrants(_ done: @escaping (Bool) -> Void) {
    func afterSpeech(_ granted: Bool) {
      guard granted else { done(false); return }
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { mic in done(mic) }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { mic in done(mic) }
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
    stopping = true
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