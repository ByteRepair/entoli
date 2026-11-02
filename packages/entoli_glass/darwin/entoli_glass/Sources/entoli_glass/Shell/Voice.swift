import SwiftUI

/// `VoiceSnapshot`.
struct VoiceState: Decodable, Equatable {
  struct Line: Decodable, Equatable {
    var kind: String
    var text: String
  }

  var present = false
  var title = "Voice"
  var status = "off"
  var word = ""
  var paused = false
  var hushed = false
  var pushToTalk = false
  var on = false
  var error: String?
  var lines: [Line] = []
  var heard = 0xFF6C_63FF
  var spoken = 0xFF2D_D4BF

  var mode: GlowMode {
    if hushed || status == "off" || status == "failed" { return .still }
    switch status {
    case "starting": return .starting
    case "thinking": return .thinking
    case "speaking": return .speaking
    default: return .listening
    }
  }
}

extension Color {
  /// An ARGB the way Dart's `toARGB32` gives one.
  init(argb: Int) {
    self.init(
      red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
      blue: Double(argb & 0xFF) / 255, opacity: Double((argb >> 24) & 0xFF) / 255)
  }
}

/// Voice mode, over the whole window: the glow under the word for what it is
/// doing, five lines of what has been said, the turn's surface, and three
/// buttons with one promise each — the microphone, the reply, and going back
/// to typing. Dart's `ShellVoice` says what is there and runs what is pressed;
/// the session lives as long as Flutter's page under this does.
struct VoiceView: View {
  @ObservedObject var model: ShellModel

  /// Whether Talk is held down, so a release is said once.
  @State private var holding = false

  private var voice: VoiceState { model.voice }
  private var heard: Color { Color(argb: voice.heard) }
  private var spoken: Color { Color(argb: voice.spoken) }

  /// The word's dot and the Stop button wear what is doing the talking.
  private var tint: Color {
    switch voice.mode {
    case .still: voice.status == "failed" ? .red : .secondary
    case .speaking: spoken
    default: heard
    }
  }

  private func say(_ name: String, _ args: [String: Any] = [:]) {
    model.intent("voice", ["name": name, "args": args])
  }

  var body: some View {
    ZStack {
      Rectangle().fill(.background).ignoresSafeArea()
      VStack(spacing: 14) {
        Text(voice.title).font(.headline).lineLimit(1).padding(.top, 8)
        Spacer(minLength: 0)
        ZStack {
          VoiceGlow(mode: voice.mode, heard: heard, spoken: spoken, level: model.voiceLevel)
          GlassDisc().frame(width: 150, height: 150)
        }
        .frame(maxWidth: 360, maxHeight: 360)
        HStack(spacing: 8) {
          Circle().fill(tint).frame(width: 8, height: 8)
          Text(voice.word).font(.title3.weight(.medium))
            .contentTransition(.interpolate)
        }
        .accessibilityElement(children: .combine)
        if let error = voice.error {
          Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
        }
        Spacer(minLength: 0)
        transcript
        TurnSurfaceView(model: model)
          .frame(maxWidth: ShellView.readableWidth + 16)
        controls.padding(.bottom, 16)
      }
      .padding(.horizontal, 24)
      .animation(.smooth, value: voice)
    }
    #if os(macOS)
      .onExitCommand { say("done") }
    #endif
  }

  /// The last lines said, the newest at the bottom, the top fading into the
  /// light above it.
  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(voice.lines.enumerated()), id: \.offset) { i, line in
            Text(line.text)
              .font(line.kind == "activity" ? .callout : .body)
              .foregroundStyle(
                line.kind == "replied"
                  ? AnyShapeStyle(.primary)
                  : line.kind == "said" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
              )
              .italic(line.kind == "activity")
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(i)
          }
        }
        .padding(.vertical, 4)
      }
      .frame(maxWidth: ShellView.readableWidth, maxHeight: 130)
      .mask(
        LinearGradient(
          stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
          startPoint: .top, endPoint: .bottom)
      )
      .onChange(of: voice.lines.count, initial: true) { _, count in
        guard count > 0 else { return }
        withAnimation(.smooth) { proxy.scrollTo(count - 1, anchor: .bottom) }
      }
    }
  }

  private var controls: some View {
    GlassGroup(spacing: 28) {
      HStack(spacing: 28) {
        if voice.pushToTalk {
          key(
            voice.paused ? "mic" : "mic.fill", "Talk", help: "Hold to talk",
            held: !voice.paused, enabled: voice.on
          ) {}
          .simultaneousGesture(
            DragGesture(minimumDistance: 0)
              .onChanged { _ in
                guard voice.on, !holding else { return }
                holding = true
                say("talk", ["on": true])
              }
              .onEnded { _ in
                guard holding else { return }
                holding = false
                say("talk", ["on": false])
              })
        } else {
          key(
            voice.paused ? "mic.slash" : "mic", voice.paused ? "Listen" : "Mute",
            help: voice.paused ? "Open the microphone" : "Shut the microphone",
            held: voice.paused, enabled: voice.on
          ) { say("mute") }
        }
        key(
          "stop.fill", "Stop", help: "Stop the reply",
          tint: voice.status == "speaking" ? spoken : nil,
          enabled: voice.status == "speaking"
        ) { say("stop") }
        key("chevron.down", "Done", help: "Back to typing") { say("done") }
      }
    }
  }

  private func key(
    _ symbol: String, _ label: String, help: String, tint: Color? = nil, held: Bool = false,
    enabled: Bool = true, action: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 6) {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.title3.weight(.medium))
          .frame(width: 52, height: 52)
          .contentShape(Circle())
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .opacity(enabled ? 1 : 0.4)
      .glassSurface(Circle(), tint: tint ?? (held ? Color.secondary.opacity(0.4) : nil))
      .help(help)
      .accessibilityLabel(label)
      Text(label).font(.caption).foregroundStyle(enabled ? .secondary : .tertiary)
    }
  }
}

/// The glass the light shines through: the system's clear glass where it has
/// it, and nothing before that, where the light alone is the orb.
private struct GlassDisc: View {
  var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      Color.clear.glassEffect(.clear, in: Circle())
    } else {
      Color.clear
    }
  }
}
