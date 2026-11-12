import SwiftUI

/// One message as the core laid it out: the speaker over it where there is
/// one, its blocks in order, and the row of what can be done to it, shown
/// on hover or on a tap.
struct MessageView: View {
  let key: String
  let message: MessageSnapshot
  let model: TranscriptModel
  /// A transcript inside a detail: its own actions are only copy.
  var nested = false

  @State private var shown = false

  private var alignment: HorizontalAlignment { message.user ? .trailing : .leading }

  var body: some View {
    VStack(alignment: alignment, spacing: 2) {
      if let speaker = message.speaker {
        HStack(spacing: 6) {
          if let bot = message.bot, let settings = SettingsModel.shared {
            // Live where it is the newest message's, thinking while the
            // reply is written; a tap makes it happy, as in the Flutter app.
            BotFaceView(
              model: settings, key: bot, colour: Int(message.botColour ?? 0), size: 45,
              mood: Int(message.botMood), live: message.botLive, reactToTap: true)
          } else if let face = message.face, let image = FaceImage.of(face.data) {
            image.resizable().frame(width: 28, height: 28).clipShape(Circle())
          }
          Text(speaker).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
      }
      ForEach(Array(message.blocks.enumerated()), id: \.offset) { index, block in
        BlockView(
          row: key, index: index, block: block, model: model, user: message.user,
          reply: nested ? nil : { model.reply(key, $0) })
      }
      if !nested {
        MessageActionRow(key: key, message: message, model: model, shown: shown)
      }
    }
    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    #if os(macOS)
      .onHover { shown = $0 }
    #else
      .onTapGesture { shown.toggle() }
    #endif
  }
}

private enum FaceImage {
  static func of(_ data: Data) -> Image? {
    #if os(iOS)
      UIImage(data: data).map { Image(uiImage: $0) }
    #else
      NSImage(data: data).map { Image(nsImage: $0) }
    #endif
  }
}

/// One block of a message.
private struct BlockView: View {
  let row: String
  let index: Int
  let block: BlockSnapshot
  let model: TranscriptModel
  let user: Bool
  let reply: ((String) -> Void)?

  var body: some View {
    switch block.kind {
    case .bubble:
      Bubble(row: row, index: index, block: block, model: model, user: user, reply: reply)
    case .steer:
      VStack(alignment: .trailing, spacing: 2) {
        if let heading = block.heading {
          Text(heading).font(.caption).foregroundStyle(.secondary).padding(.trailing, 4)
        }
        Bubble(row: row, index: index, block: block, model: model, user: true, reply: reply)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .activity:
      ForEach(block.nodes, id: \.id) { NodeView(node: $0, model: model) }
        .frame(maxWidth: .infinity, alignment: .leading)
    case .activityRun:
      ActivityRunView(nodes: block.nodes, model: model)
        .id("\(row)/run/\(block.runStart)")
    case .file:
      Files(row: row, index: index, files: block.files, model: model)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .shellRun:
      if let shell = block.shell { ShellRunView(shell: shell) }
    }
  }
}

/// What was said: on the page for a reply, on a fill held to four fifths of
/// the line for everything else, pushed to the trailing edge for the user's.
private struct Bubble: View {
  let row: String
  let index: Int
  let block: BlockSnapshot
  let model: TranscriptModel
  let user: Bool
  let reply: ((String) -> Void)?

  var body: some View {
    let content = VStack(alignment: .leading, spacing: 4) {
      if !block.files.isEmpty {
        Files(row: row, index: index, files: block.files, model: model)
      }
      ForEach(Array(block.said.enumerated()), id: \.offset) { _, said in
        SaidView(said: said, model: model, reply: reply, hugs: Self.fill(block.tint) != nil)
      }
      ForEach(Array(block.trailing.enumerated()), id: \.offset) { _, trailing in
        TrailingView(row: row, trailing: trailing, model: model)
      }
    }
    if let fill = Self.fill(block.tint) {
      CappedWidth(fraction: 0.8, trailing: user) {
        content
          .padding(10)
          .background(fill, in: RoundedRectangle(cornerRadius: 12))
      }
    } else {
      content.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  static func fill(_ tint: Tint) -> AnyShapeStyle? {
    switch tint {
    case .none: nil
    case .prompt: AnyShapeStyle(Color.accentColor.opacity(0.18))
    case .command: AnyShapeStyle(.quaternary)
    case .notice, .tool, .system: AnyShapeStyle(Color.orange.opacity(0.14))
    }
  }
}

private struct SaidView: View {
  let said: SaidSnapshot
  let model: TranscriptModel
  let reply: ((String) -> Void)?
  /// In a bubble, which is as wide as what it says.
  var hugs = false

  var body: some View {
    switch said.kind {
    case .prose:
      MarkdownView(
        blocks: said.blocks, model: model, caret: said.caret, reply: reply, hugs: hugs)
    case .error:
      Text(said.text).foregroundStyle(.red).textSelection(.enabled)
    case .command:
      Text("! \(said.text)").font(.system(.body, design: .monospaced)).textSelection(.enabled)
    }
  }
}

private struct TrailingView: View {
  let row: String
  let trailing: TrailingSnapshot
  let model: TranscriptModel

  var body: some View {
    switch trailing.kind {
    case .waiting:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ProgressView().controlSize(.small)
        if let line = trailing.line {
          Text(line).font(.caption).foregroundStyle(
            trailing.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
      }
      .padding(.vertical, 2)
    case .liveOutput:
      OutputBox { Text(trailing.line ?? "").lineLimit(12) }
    case .retry:
      Button("Retry", systemImage: "arrow.clockwise") { model.act(row, .regenerate) }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
  }
}

/// A command the user ran and what it printed.
private struct ShellRunView: View {
  let shell: ShellRunSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("$ \(shell.command)").font(.system(.body, design: .monospaced))
      if !shell.output.isEmpty {
        OutputBox { Text(shell.output.trimmingCharacters(in: .newlines)) }
      }
      if let code = shell.exitCode, code != 0 {
        Text("Exit code \(code)").font(.caption).foregroundStyle(.red)
      }
    }
    .textSelection(.enabled)
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// Attachments: an image as a thumbnail, anything else by its name; a tap
/// opens it where this device has it.
private struct Files: View {
  let row: String
  let index: Int
  let files: [FileSnapshot]
  let model: TranscriptModel

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(files.enumerated()), id: \.offset) { file, snapshot in
          Button {
            model.openFile(row, block: index, file: file)
          } label: {
            chip(snapshot)
          }
          .buttonStyle(.plain)
          .disabled(snapshot.path == nil)
        }
      }
    }
  }

  @ViewBuilder private func chip(_ file: FileSnapshot) -> some View {
    if let path = file.path, file.mime?.hasPrefix("image/") == true {
      AsyncImage(url: URL(fileURLWithPath: path)) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Rectangle().fill(.quaternary)
      }
      .frame(width: 96, height: 96)
      .clipShape(RoundedRectangle(cornerRadius: 10))
    } else {
      Label(file.name, systemImage: "doc")
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
  }
}

/// What can be done to a message: its reactions always, the rest while the
/// pointer is over it or after a tap. Kept the same height either way, so
/// nothing shifts as it appears.
private struct MessageActionRow: View {
  let key: String
  let message: MessageSnapshot
  let model: TranscriptModel
  let shown: Bool

  @State private var deleting = false
  @State private var reacting = false
  @State private var editing = false
  @State private var edited = ""

  private var actions: ActionsSnapshot { message.actions }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(message.reactions, id: \.self) { Text($0) }
      HStack(spacing: 2) {
        if let threads = actions.threads {
          Text(threads).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
          icon("chevron.left", "Previous thread", on: actions.previous) {
            model.act(key, .previous)
          }
          icon("chevron.right", "Next thread", on: actions.next) { model.act(key, .next) }
        }
        if actions.copy {
          icon("doc.on.doc", "Copy message") { model.act(key, .copy) }
          icon("chevron.left.forwardslash.chevron.right", "Copy raw markdown") {
            model.act(key, .copyRaw)
          }
        }
        if actions.react {
          icon("face.smiling", "React") { reacting = true }
            // Master's strip: a popover from the smiley, in the system's
            // glass, the reactions already given tinted; one picked again is
            // taken back.
            .popover(isPresented: $reacting, arrowEdge: .top) {
              GlassChoices(
                choices: model.reactions.map {
                  ($0.emoji, $0.name, message.reactions.contains($0.emoji))
                },
                pick: { index in
                  reacting = false
                  model.react(key, model.reactions[index].emoji)
                }
              )
              .presentationCompactAdaptation(.popover)
            }
        }
        if actions.speak {
          icon(
            actions.speaking ? "stop.circle" : "speaker.wave.2",
            actions.speaking ? "Stop reading" : "Read aloud"
          ) { model.act(key, .speak) }
        }
        if actions.delete {
          icon("trash", "Delete thread") { deleting = true }
        }
        if actions.edit {
          icon("pencil", "Edit") {
            edited = actions.editText
            editing = true
          }
        }
        if actions.regenerate {
          icon("arrow.clockwise", "Regenerate") { model.act(key, .regenerate) }
        }
      }
      // Up while its strip is, or the popover would lose what it points at.
      .opacity(shown || actions.speaking || reacting ? 1 : 0)
      .allowsHitTesting(shown || actions.speaking || reacting)
      .animation(.easeOut(duration: 0.12), value: shown)
    }
    .frame(height: 28)
    .environment(\.layoutDirection, message.user ? .rightToLeft : .leftToRight)
    .confirmationDialog("Delete thread", isPresented: $deleting) {
      Button("Delete", role: .destructive) { model.act(key, .delete) }
    } message: {
      Text(actions.deleteQuestion)
    }
    .sheet(isPresented: $editing) {
      EditSheet(text: $edited) { model.edit(key, edited) }
    }
  }

  private func icon(
    _ symbol: String, _ help: String, on: Bool = true, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 24, height: 24)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(!on)
    .help(help)
    .environment(\.layoutDirection, .leftToRight)
  }
}

/// A message's text to change and send again.
private struct EditSheet: View {
  @Binding var text: String
  let send: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TextEditor(text: $text)
        .font(.body)
        .padding()
        .navigationTitle("Edit message")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Send") {
              send()
              dismiss()
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
    }
    .frame(minWidth: 480, minHeight: 320)
  }
}

/// Its one child at most [fraction] of the width it is offered — the reading
/// column, not the window — as wide as it asks within that, and held to the
/// trailing edge for [trailing]: a prompt's bubble.
private struct CappedWidth: Layout {
  let fraction: CGFloat
  let trailing: Bool

  private func childSize(_ subviews: Subviews, width: CGFloat?) -> CGSize {
    subviews.first?.sizeThatFits(ProposedViewSize(width: width.map { $0 * fraction }, height: nil))
      ?? .zero
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let child = childSize(subviews, width: proposal.width)
    return CGSize(width: proposal.width ?? child.width, height: child.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let child = childSize(subviews, width: bounds.width)
    let x = trailing ? bounds.maxX - child.width : bounds.minX
    subviews.first?.place(
      at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(child))
  }
}

/// What a command printed: monospaced, scrolled sideways rather than
/// wrapped, on a tinted box.
struct OutputBox<Content: View>: View {
  var padding: CGFloat = 10
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView(.horizontal) {
      content.font(.system(size: 12.5, design: .monospaced)).padding(padding)
    }
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
  }
}
