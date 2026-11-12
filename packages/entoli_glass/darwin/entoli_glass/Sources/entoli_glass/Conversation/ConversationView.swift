import SwiftUI

/// The conversation, drawn natively from the core's transcript: a lazy list
/// of rows by key, held to the reading column, kept to the end while the
/// reader is there and offering the way back once they leave it. Links and
/// details go to Dart; a detail comes back as a sheet.
struct ConversationView: View {
  @Bindable var model: TranscriptModel

  /// How far up from the bottom edge the conversation keeps clear: what
  /// covers it there, less what only lies over it — the composer's menu. It
  /// runs under the bottom edge and pads by this instead of following the
  /// safe area, which a menu opening would move.
  var bottom: CGFloat = 0

  @State private var atEnd = true
  /// Whether it all fits with nothing to scroll.
  @State private var fits = true

  /// The row at the top of the view, which says which chapter is being read.
  @State private var top: String?

  /// How wide the conversation is, which says whether the margin beside the
  /// column has room for the chapter rail.
  @State private var width: CGFloat = 0

  /// The column and its padding, as laid out below.
  private static let column = ShellView.readableWidth + 32

  /// The margin beside the column on each side.
  private var margin: CGFloat { max(0, (width - Self.column) / 2) }

  /// The rail only where the margin beside the column holds it, so it never
  /// lies over what the column shows.
  private var railFits: Bool { margin >= ChapterRail.width }

  /// What comes and goes beside the column, as the new-chat screen's
  /// question comes and goes.
  private static let appear = AnyTransition.asymmetric(insertion: .opacity, removal: .lift)
  private static let motion = Animation.easeOut(duration: 0.35)

  /// The jump button: in the margin beside the column where it has room,
  /// else inside the column's corner.
  private static let jumpSize: CGFloat = 36
  private var jumpInset: CGFloat {
    margin >= Self.jumpSize + 16 ? margin - Self.jumpSize - 8 : 16
  }

  private var detailShown: Binding<Bool> {
    Binding(
      get: { model.detail.present },
      set: { if !$0 { model.closeDetail() } })
  }

  /// The last chapter at or above the top of the view.
  private var current: Int? {
    guard let top, let at = model.order.firstIndex(of: top) else { return nil }
    let index = Dictionary(
      model.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return model.chapters.lastIndex { (index[$0.row] ?? .max) <= at }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Rows(model: model)
          .scrollTargetLayout()
        // Placed from the view's whole width, not the content's: a scroller
        // takes its strip from the content, which moved a centred column off
        // the composer's line whenever one came. As wide as it may be up to
        // the reading width, so it narrows with the window; a fixed width
        // held the scroll view, and the width read off it, where they were.
        .frame(maxWidth: ShellView.readableWidth)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.leading, margin)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // Which rows are shown, from the first layout on: a scroll position
      // is only said once the user scrolls, so the rail lit nothing as a
      // chat opened.
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { shown in
        let seen = Set(shown)
        top = model.order.first { seen.contains($0) }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .overlay(alignment: .trailing) {
        if railFits && model.chapters.count > 1 {
          ChapterRail(chapters: model.chapters, current: current) { chapter in
            withAnimation(.smooth) { proxy.scrollTo(chapter.row, anchor: .top) }
          }
          // Against the column, in the margin beside it.
          .padding(.trailing, margin - ChapterRail.width)
          .padding(.bottom, bottom)
          .transition(Self.appear)
        }
      }
      .animation(Self.motion, value: railFits)
      .overlay {
        if model.order.isEmpty && !model.loading {
          Text("No messages yet").foregroundStyle(.secondary)
        }
      }
      .contentMargins(.bottom, bottom, for: .scrollContent)
      .contentMargins(.bottom, bottom, for: .scrollIndicators)
      // Opened at the end, and a size change keeps the end in view only from
      // the end, so opening something above leaves what is shown where it
      // is. Not `.alignment` to the bottom: holding a chat too short to
      // scroll at the foot made the title bar's scroll edge flash on and off
      // as a run in it opened.
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(atEnd ? .bottom : .top, for: .sizeChanges)
      // At the end where what is shown reaches the content's last line. The
      // margin under it is not added: the content's size may already hold
      // it, and adding it twice left the button up at the very bottom.
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.maxY >= geometry.contentSize.height - 40
      } action: { _, end in
        atEnd = end
      }
      // No scroller while there is nothing to scroll. `never`, not
      // `hidden`: with scroll bars always shown, as with a mouse attached,
      // `hidden` is overridden and the scroller flashed at a run opened.
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentSize.height < geometry.containerSize.height - 1
      } action: { _, short in
        fits = short
      }
      .scrollIndicators(fits ? .never : .automatic)
      #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
      #endif
      .overlay(alignment: .bottomTrailing) {
        if !atEnd, let last = model.order.last {
          Button {
            withAnimation(.smooth) { proxy.scrollTo(last, anchor: .bottom) }
          } label: {
            Image(systemName: "arrow.down").padding(10)
          }
          .buttonStyle(.plain)
          .glassCircle()
          .help("Jump to latest")
          .padding(.trailing, jumpInset)
          .padding(.bottom, bottom + 12)
          .transition(Self.appear)
        }
      }
      .animation(Self.motion, value: atEnd)
    }
    .sheet(isPresented: detailShown) {
      DetailView(model: model)
    }
  }
}

private extension View {
  @ViewBuilder func glassCircle() -> some View {
    if #available(iOS 26, macOS 26, *) {
      glassEffect(.regular.interactive(), in: Circle())
    } else {
      background(.regularMaterial, in: Circle())
    }
  }
}

/// A row by its kind: a message, or a line between them.
private struct RowView: View {
  let row: RowSnapshot
  let model: TranscriptModel

  var body: some View {
    switch row.kind {
    case .message:
      if let message = row.message {
        MessageView(key: row.key, message: message, model: model)
      }
    case .mode:
      Separator(text: row.text)
    case .compaction, .compactionFailed:
      SummarySeparator(row: row, model: model)
    case .goal:
      Label(row.text, systemImage: row.icon.symbol)
        .font(.callout)
        .foregroundStyle(row.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .padding(.vertical, 6)
    }
  }
}

private struct Separator: View {
  let text: String
  var colour: Color = .secondary

  var body: some View {
    HStack(spacing: 10) {
      line
      Text(text).font(.caption).foregroundStyle(colour)
      line
    }
    .padding(.vertical, 10)
  }

  private var line: some View { Rectangle().fill(.quaternary).frame(height: 1) }
}

/// Where a compaction took over, the summary behind a disclosure.
private struct SummarySeparator: View {
  let row: RowSnapshot
  let model: TranscriptModel
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.snappy(duration: 0.2)) { open.toggle() }
      } label: {
        Separator(text: row.text, colour: row.isError ? .red : .secondary)
      }
      .buttonStyle(.plain)
      if open {
        MarkdownView(blocks: row.body, model: model, tone: row.isError ? .red : nil)
          .padding(.bottom, 8)
      }
    }
  }
}

/// What is behind an activity: its title and actions in the bar, its
/// status, the command set apart, its sections, and a sub-agent's own reply
/// under them, all as Dart last sent them, so an open one keeps following
/// its turn.
struct DetailView: View {
  let model: TranscriptModel
  @Environment(\.dismiss) private var dismiss

  private var detail: DetailSnapshot { model.detail }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if detail.live || detail.status != nil {
              HStack(spacing: 8) {
                if detail.live { ProgressView().controlSize(.small) }
                if let status = detail.status {
                  Text(status).font(.callout).foregroundStyle(
                    detail.statusError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
              }
            }
            if let command = detail.command {
              Text("$ \(command)")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            }
            ForEach(Array(detail.sections.enumerated()), id: \.offset) { _, section in
              VStack(alignment: .leading, spacing: 6) {
                if let label = section.label {
                  Text(label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                sectionBody(section)
              }
            }
            if let transcript = detail.transcript {
              MessageView(key: "detail", message: transcript, model: model, nested: true)
            }
            Color.clear.frame(height: 1).id("end")
          }
          .frame(maxWidth: 900, alignment: .leading)
          .padding(20)
          .frame(maxWidth: .infinity)
        }
        .onChange(of: detail) { _, now in
          if now.live { proxy.scrollTo("end", anchor: .bottom) }
        }
      }
      .navigationTitle(detail.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ForEach(Array(detail.actions.enumerated()), id: \.offset) { index, action in
          ToolbarItem(placement: .primaryAction) {
            Button(action.label) { model.detailAction(index) }
              .disabled(!action.enabled)
              .help(action.why ?? action.label)
          }
        }
      }
    }
    .frame(minWidth: 560, minHeight: 420)
  }

  @ViewBuilder private func sectionBody(_ section: SectionSnapshot) -> some View {
    let text = Text(detail.mono ? section.body.trimmingCharacters(in: .newlines) : section.body)
      .foregroundStyle(section.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
      .textSelection(.enabled)
    if detail.mono {
      OutputBox(padding: 12) { text }
    } else {
      text.lineSpacing(3)
    }
  }
}

/// The conversation's rows. Up to a few hundred every row is laid out, as
/// the Flutter app measures them all (`_MeasureAll`): a lazy stack guesses
/// the height of the rows away from the view, and the scroller started at
/// the guess and snapped to the truth as they came in. Past that one row's
/// error no longer moves it, and laying them all out is work nobody sees.
private struct Rows: View {
  let model: TranscriptModel
  private static let measuredUpTo = 400

  var body: some View {
    if model.order.count <= Self.measuredUpTo {
      VStack(alignment: .leading, spacing: 0) { rows }
    } else {
      LazyVStack(alignment: .leading, spacing: 0) { rows }
    }
  }

  private var rows: some View {
    ForEach(model.order, id: \.self) { key in
      if let row = model.rows[key] {
        RowView(row: row, model: model).id(key)
      }
    }
  }
}
