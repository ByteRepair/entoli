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

  /// Each chapter's row's top edge against the top of the view, as it was
  /// last laid out: which chapter is being read.
  @State private var chapterTops: [String: CGFloat] = [:]
  /// Scrolled to the very end, with no slack.
  @State private var atBottom = true
  /// The chapter being read, as `readChapter` last found it.
  @State private var current: Int?

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

  /// Which chapter the view is in, as the Flutter page reads it
  /// (`_readChapter`): from the prompts laid out, against the top of the
  /// view — the scroll view's own, under the title bar, as the Flutter list
  /// scrolls under it too. One laid out below the top means the one before
  /// it is being read; none laid out at all leaves the answer where it was.
  private func readChapter() {
    let chapters = model.chapters
    // At the end the last prompt can be too near the bottom ever to reach
    // the top, and it is the one being read.
    if !chapters.isEmpty && atBottom {
      current = chapters.count - 1
      return
    }
    var at: Int?
    for (i, chapter) in chapters.enumerated() {
      guard let top = chapterTops[chapter.row] else { continue }
      if top <= 24 {
        at = i
      } else {
        if at == nil { at = i == 0 ? 0 : i - 1 }
        break
      }
    }
    if let at { current = at }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Rows(model: model) { row, top in chapterTops[row] = top }
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
      // A scroller per chat, made once its rows are in: the view stays up
      // between chats, and the initial offset below is only a new
      // scroller's, so the next chat otherwise opened at the last one's.
      .id(model.loading ? nil : model.chatId)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .onChange(of: chapterTops) { readChapter() }
      .onChange(of: atBottom) { readChapter() }
      .onChange(of: model.chapters) { readChapter() }
      .onChange(of: model.chatId) {
        chapterTops = [:]
        current = nil
        atEnd = true
      }
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
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.maxY >= geometry.contentSize.height - 1
      } action: { _, end in
        atBottom = end
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
  let entry: RowEntry
  let model: TranscriptModel

  var body: some View {
    let row = entry.snapshot
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
  /// A chapter's row's top against the view's, as it is laid out and as the
  /// view scrolls: from the first layout on, where a scroll position is said
  /// only once the user scrolls. A lazy stack's rows away from the view say
  /// nothing until they come near.
  let chapterTop: (String, CGFloat) -> Void
  private static let measuredUpTo = 400

  var body: some View {
    if model.order.count <= Self.measuredUpTo {
      VStack(alignment: .leading, spacing: 0) { rows }
    } else {
      LazyVStack(alignment: .leading, spacing: 0) { rows }
    }
  }

  private var rows: some View {
    let chapters = Set(model.chapters.map(\.row))
    return ForEach(model.order, id: \.self) { key in
      if let entry = model.rows[key] {
        RowView(entry: entry, model: model).id(key)
          .modifier(TopReport(key: key, reports: chapters.contains(key), report: chapterTop))
      }
    }
  }
}

/// [report] of the row's top against the view's, where it [reports].
private struct TopReport: ViewModifier {
  let key: String
  let reports: Bool
  let report: (String, CGFloat) -> Void

  func body(content: Content) -> some View {
    if reports {
      content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: {
        report(key, $0)
      }
    } else {
      content
    }
  }
}
