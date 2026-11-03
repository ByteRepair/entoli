import SwiftUI

/// The composer: the menu, the working directory and the attachments over a
/// row of the `+` menu, the field and its buttons. It sits in the shell's
/// bottom safe-area inset, at its own height, which the conversation is told
/// as padding the way it is told the toolbar's.
///
/// Every change it draws is animated, and on one curve: a control that comes
/// or goes is morphed by the system's glass rather than popped, the menu's
/// highlight glides between rows, and the field grows a line at a time.
struct ComposerView: View {
  @ObservedObject var model: ComposerModel
  @Namespace private var glass
  @Namespace private var menuRows

  /// One menu row's height, and how many show before the list scrolls.
  private static let rowHeight: CGFloat = 36
  private static let visibleRows = 5

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
    var mode: ComposerMode
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
    .tint(model.accent)
    .environment(\.colorScheme, model.dark ? .dark : .light)
    .animation(Self.motion, value: shape)
    .animation(Self.motion, value: model.highlighted)
  }

  // MARK: The row

  private var plus: some View {
    Menu {
      Button {
        model.say?.attach(kind: .image) { _ in }
      } label: {
        Label("Image", systemImage: "photo")
      }
      Button {
        model.say?.attach(kind: .file) { _ in }
      } label: {
        Label("File", systemImage: "paperclip")
      }
      Divider()
      Button {
        model.say?.trigger(kind: .skill) { _ in }
      } label: {
        Label("Command", systemImage: "slash.circle")
      }
      Button {
        model.say?.trigger(kind: .agent) { _ in }
      } label: {
        Label("Agent", systemImage: "at")
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
          Text(model.hint)
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
      button("voice", "Voice mode", systemImage: "waveform") { model.say?.voice { _ in } }
    }
    if model.queues {
      button("queue", "Send after this turn", systemImage: "clock") { model.say?.queue { _ in } }
    }
    if model.speaking && !model.canSend {
      button("send", "Stop", systemImage: "stop.fill", prominent: true) { model.say?.stop { _ in } }
    } else {
      button(
        "send", model.sendLabel, systemImage: sendSymbol, prominent: model.canSend
      ) { model.say?.send { _ in } }
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
      tint: prominent ? model.accent.opacity(Self.prominence) : nil)
    .help(label)
    .accessibilityLabel(label)
  }

  // MARK: Above the row

  private var menu: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.menu) { option in
            Button {
              model.say?.pick(index: Int64(option.id)) { _ in }
            } label: {
              menuRow(option)
            }
            .buttonStyle(.plain)
            .id(option.id)
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

  private func menuRow(_ option: ComposerOption) -> some View {
    HStack(spacing: 8) {
      Text(option.label).fontWeight(.semibold).lineLimit(1)
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
      if option.id == model.highlighted {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.tint.opacity(0.22))
          .padding(.horizontal, 4)
          .matchedGeometryEffect(id: "highlight", in: menuRows)
      }
    }
  }

  private func cwdRow(_ cwd: String) -> some View {
    Button {
      model.say?.copyCwd { _ in }
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
