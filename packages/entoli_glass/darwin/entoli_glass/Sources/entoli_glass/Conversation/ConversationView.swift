import SwiftUI

/// The conversation, drawn natively from the core's transcript: a lazy list
/// of rows by key, held to the reading column, kept to the end while the
/// reader is there and offering the way back once they leave it. Links and
/// details go to Dart; a detail comes back as a sheet.
struct ConversationView: View {
  @Bindable var model: TranscriptModel

  @State private var atEnd = true

  private var detailShown: Binding<Bool> {
    Binding(
      get: { model.detail.present },
      set: { if !$0 { model.closeDetail() } })
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.order, id: \.self) { key in
            if let row = model.rows[key] {
              RowView(row: row, model: model).id(key)
            }
          }
        }
        .frame(maxWidth: ShellView.readableWidth)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
      }
      .overlay {
        if model.order.isEmpty {
          Text("No messages yet").foregroundStyle(.secondary)
        }
      }
      .defaultScrollAnchor(.bottom)
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.containerSize.height
          >= geometry.contentSize.height - 40
      } action: { _, end in
        atEnd = end
      }
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
          .padding(16)
          .transition(.opacity)
        }
      }
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        model.link(url.absoluteString)
        return .handled
      }
    )
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
      ScrollView(.horizontal) {
        text.font(.system(size: 12.5, design: .monospaced)).padding(12)
      }
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    } else {
      text.lineSpacing(3)
    }
  }
}
