import SwiftUI

/// Where this frontend puts a composer action: a button laid out by hand, or
/// an entry of the `+` menu.
enum ComposerPlace {
  case button
  case plus(label: String, symbol: String, group: Int)
}

extension ComposerAction {
  /// Every action, in the contract's order: Pigeon's enums are not
  /// `CaseIterable`.
  static let all: [ComposerAction] = Array(
    sequence(first: 0) { $0 + 1 }.lazy.map { ComposerAction(rawValue: $0) }
      .prefix { $0 != nil }.compactMap { $0 })

  /// Exhaustive, with no default: a new action does not compile until it has
  /// a place here, or is left out on purpose. The Flutter composer has its
  /// own, and the two differ where the platforms do.
  var place: ComposerPlace {
    switch self {
    case .send, .queue, .stop, .voice: .button
    case .attachImage: .plus(label: "Image", symbol: "photo", group: 0)
    case .attachFile: .plus(label: "File", symbol: "paperclip", group: 0)
    case .insertSkill: .plus(label: "Command", symbol: "slash.circle", group: 1)
    case .insertAgent: .plus(label: "Agent", symbol: "at", group: 1)
    case .newGoal: .plus(label: "New Goal", symbol: "scope", group: 2)
    }
  }
}

/// The composer: the menu, the working directory and the attachments over a
/// row of the `+` menu, the field and its buttons. It sits in the shell's
/// bottom safe-area inset, at its own height, which the conversation is told
/// as padding the way it is told the toolbar's.
///
/// Every change it draws is animated, and on one curve: a control that comes
/// or goes is morphed by the system's glass rather than popped, the menu's
/// highlight glides between rows, and the field grows a line at a time.
struct ComposerView: View {
  var model: ComposerModel
  @Namespace private var glass
  @Namespace private var menuRows

  /// One menu row's height, and how many show before the list scrolls.
  private static let rowHeight: CGFloat = 36
  private static let visibleRows = 5

  /// How much higher the composer stands while its menu of [rows] is up:
  /// the menu and the gap under it. The native conversation discounts it,
  /// so the menu lies over the chat rather than lifting it.
  static func menuLift(rows: Int) -> CGFloat {
    rows == 0 ? 0 : rowHeight * CGFloat(min(rows, visibleRows)) + 8 + 8
  }

  /// An agent's face in a menu row: the size Dart draws it at, `_menuFace`
  /// in `shell_composer.dart`.
  private static let menuFace: CGFloat = 22

  /// A button's side, which the field's single line is held to as well, so
  /// the row is level.
  static let control: CGFloat = 40

  static let motion = Animation.snappy(duration: 0.22)

  /// How much of the accent a prominent button's glass takes: enough to say
  /// it is the one to press, little enough that it is still glass the
  /// conversation shows through rather than a solid disc.
  private static let prominence = 0.55

  /// Everything that changes what the view lays out, so one animation
  /// carries all of it.
  private struct Shape: Equatable {
    var canSend, queues, speaking, voice: Bool
    var mode: InputMode
    var menu: Int
    var attachments: [ComposerAttachment]
    var cwd: Bool
  }

  private var shape: Shape {
    Shape(
      canSend: model.canSend, queues: model.queues, speaking: model.speaking,
      voice: model.voice, mode: model.mode, menu: model.menu.count,
      attachments: model.attachments, cwd: model.cwd != nil)
  }

  var body: some View {
    VStack(spacing: 8) {
      if !model.menu.isEmpty { menu }
      if let cwd = model.cwd { cwdRow(cwd) }
      if !model.attachments.isEmpty { attachmentRow }
      GlassGroup {
        HStack(alignment: .bottom, spacing: 8) {
          plus
          field
          trailing
        }
      }
    }
    .padding(8)
    .fixedSize(horizontal: false, vertical: true)
    .animation(Self.motion, value: shape)
    .animation(Self.motion, value: model.highlighted)
  }

  // MARK: The row

  /// The `+` menu's entries, grouped as [ComposerAction.place] says.
  private static let plusGroups: [[(ComposerAction, String, String)]] = {
    var groups: [Int: [(ComposerAction, String, String)]] = [:]
    for action in ComposerAction.all {
      if case .plus(let label, let symbol, let group) = action.place {
        groups[group, default: []].append((action, label, symbol))
      }
    }
    return groups.keys.sorted().map { groups[$0]! }
  }()

  private var plus: some View {
    Menu {
      ForEach(Array(Self.plusGroups.enumerated()), id: \.offset) { i, group in
        if i > 0 { Divider() }
        ForEach(group, id: \.0) { action, label, symbol in
          Button {
            model.say?.run(action: action) { _ in }
          } label: {
            Label(label, systemImage: symbol)
          }
        }
      }
    } label: {
      Image(systemName: "plus")
        .font(.body.weight(.medium))
        .frame(width: Self.control, height: Self.control)
        .contentShape(Circle())
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .glassControl("plus", in: glass, shape: Circle())
    .stretchy()
    .help("Attach or insert")
    .accessibilityLabel("Attach or insert")
  }

  private var field: some View {
    HStack(alignment: .center, spacing: 6) {
      if let symbol = modeSymbol {
        Image(systemName: symbol)
          .foregroundStyle(.tint)
          .transition(.scale.combined(with: .opacity))
      }
      ZStack(alignment: .topLeading) {
        ComposerTextField(model: model)
          .frame(height: model.fieldHeight)
        if model.empty {
          Text(hint)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
            .padding(.top, ComposerTextField.inset)
            .transition(.opacity)
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(minHeight: Self.control)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassControl(
      "field", in: glass, shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
      interactive: false)
    .stretchy()
  }

  /// What an empty field says.
  private var hint: String {
    switch model.mode {
    case .shell: "Shell command"
    case .message, .callback: "Message"
    }
  }

  /// What Send is called where it is not Stop.
  private var sendLabel: String {
    switch model.mode {
    case .shell: return "Run"
    case .message: return model.queues ? "Send now" : "Send"
    case .callback:
      switch model.callback {
      case .compact: return "Compact"
      case .setGoal: return "Set Goal"
      case .resumeGoal: return "Resume Goal"
      case .pauseGoal: return "Pause Goal"
      case .clearGoal: return "Clear Goal"
      case .showGoal: return "Show Goal"
      case nil: return "Run"
      }
    }
  }

  private var modeSymbol: String? {
    switch model.mode {
    case .shell: "terminal"
    case .callback: "sparkles"
    case .message: nil
    }
  }

  @ViewBuilder private var trailing: some View {
    if model.voice && !model.speaking && !model.canSend {
      button("voice", "Voice mode", systemImage: "waveform") { model.say?.run(action: .voice) { _ in } }
    }
    if model.queues {
      button("queue", "Send after this turn", systemImage: "clock") { model.say?.run(action: .queue) { _ in } }
    }
    if model.speaking && !model.canSend {
      button("send", "Stop", systemImage: "stop.fill", prominent: true) { model.say?.run(action: .stop) { _ in } }
    } else {
      button(
        "send", sendLabel, systemImage: sendSymbol, prominent: model.canSend
      ) { model.say?.run(action: .send) { _ in } }
      .disabled(!model.canSend)
    }
  }

  private var sendSymbol: String {
    switch model.mode {
    case .shell: "play.fill"
    case .callback: "sparkles"
    case .message: "arrow.up"
    }
  }

  private func button(
    _ id: String, _ label: String, systemImage: String, prominent: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .contentTransition(.symbolEffect(.replace))
        .frame(width: Self.control, height: Self.control)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassControl(
      id, in: glass, shape: Circle(),
      tint: prominent ? Color.accentColor.opacity(Self.prominence) : nil)
    .stretchy()
    .help(label)
    .accessibilityLabel(label)
  }

  // MARK: Above the row

  private var menu: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(model.menu.enumerated()), id: \.offset) { i, option in
            Button {
              model.say?.pick(index: Int64(i)) { _ in }
            } label: {
              menuRow(option, at: i)
            }
            .buttonStyle(.plain)
            .id(i)
          }
        }
        .padding(.vertical, 4)
      }
      .frame(
        height: Self.rowHeight * CGFloat(min(model.menu.count, Self.visibleRows)) + 8)
      .onChange(of: model.highlighted) { _, row in
        withAnimation(Self.motion) { proxy.scrollTo(row) }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .transition(
      .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
  }

  private func menuRow(_ option: ComposerMenuItem, at row: Int) -> some View {
    HStack(spacing: 8) {
      // An agent leads with its face, a still Flutter drew; one with none
      // is the person the Flutter row draws.
      if let picture = model.pictures[row] {
        picture.resizable().interpolation(.high)
          .frame(width: Self.menuFace, height: Self.menuFace)
      } else if option.trigger == .agent {
        Image(systemName: "person.crop.circle.fill")
          .resizable()
          .foregroundStyle(.secondary)
          .frame(width: Self.menuFace, height: Self.menuFace)
      }
      Text(option.trigger.glyph + option.name).fontWeight(.semibold).lineLimit(1)
      if let hint = option.hint {
        Text(hint).italic().foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 12)
      if let detail = option.detail {
        Text(detail).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: Self.rowHeight)
    .contentShape(Rectangle())
    .background {
      // One highlight, which moves: a row's own would blink out on one row
      // and in on the next.
      if row == model.highlighted {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.tint.opacity(0.22))
          .padding(.horizontal, 4)
          .matchedGeometryEffect(id: "highlight", in: menuRows)
      }
    }
  }

  private func cwdRow(_ cwd: String) -> some View {
    Button {
      copyToPasteboard(cwd)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "terminal")
        Text(cwd).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
          .contentTransition(.opacity)
        Spacer(minLength: 0)
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .glassSurface(Capsule())
    .help("Copy the working directory")
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private var attachmentRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(model.attachments.enumerated()), id: \.offset) { i, attachment in
          HStack(spacing: 6) {
            Image(systemName: attachment.image ? "photo" : "doc")
            Text(attachment.name).lineLimit(1)
            Button {
              model.say?.unattach(index: Int64(i)) { _ in }
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
          }
          .font(.callout)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .glassSurface(Capsule())
          .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }
}
