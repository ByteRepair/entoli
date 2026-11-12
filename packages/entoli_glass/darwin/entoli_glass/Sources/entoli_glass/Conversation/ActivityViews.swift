import SwiftUI

/// An activity as the core's node says it is drawn, one view per kind of
/// node. Tapping one sends its id; Dart answers with its detail, or opens
/// what a card stands for.
struct NodeView: View {
  let node: NodeSnapshot
  let model: TranscriptModel

  var body: some View {
    switch node.kind {
    case .label: LabelView(node: node, model: model)
    case .diff: DiffView(node: node, model: model)
    case .plan: PlanCard(node: node, model: model)
    case .output: OutputCard(node: node, model: model)
    }
  }
}

/// The one muted line most activities are, and while a thought is being
/// written its last lines under it, faded at the top.
private struct LabelView: View {
  let node: NodeSnapshot
  let model: TranscriptModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Button {
        model.open(node.id)
      } label: {
        HStack(spacing: 8) {
          Group {
            if node.busy {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: node.icon.symbol)
            }
          }
          .frame(width: 16, height: 16)
          Text(node.text).lineLimit(1).truncationMode(.tail)
          Image(systemName: "chevron.right").font(.caption2).opacity(0.6)
        }
        .font(.callout)
        .foregroundStyle(node.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if let tail = node.tail {
        Text(tail)
          .font(.caption)
          .italic()
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .bottomLeading)
          .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .center))
          .padding(.leading, 24)
          .onTapGesture { model.open(node.id) }
      }
    }
  }
}

/// A small change as the lines it took out and put in.
private struct DiffView: View {
  let node: NodeSnapshot
  let model: TranscriptModel

  var body: some View {
    Button {
      model.open(node.id)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Label(node.text, systemImage: "doc.text").font(.callout).foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(node.removed.enumerated()), id: \.offset) { _, line in
              Text("- \(line)").foregroundStyle(.red)
            }
            ForEach(Array(node.added.enumerated()), id: \.offset) { _, line in
              Text("+ \(line)").foregroundStyle(.green)
            }
          }
          .font(.system(size: 12.5, design: .monospaced))
        }
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// The plan put to the user, as where it stands now.
private struct PlanCard: View {
  let node: NodeSnapshot
  let model: TranscriptModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "checklist")
        VStack(alignment: .leading) {
          Text(node.text).font(.headline)
          if let progress = node.progress {
            Text(progress).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button {
          model.open(node.id)
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.borderless)
        .help("Open the plan")
      }
      ForEach(Array(node.tasks.enumerated()), id: \.offset) { _, task in
        Label(task.title, systemImage: task.done ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(task.done ? .secondary : .primary)
          .font(.callout)
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    .padding(.vertical, 6)
  }
}

/// Something the turn made for the user, as a card that opens it.
private struct OutputCard: View {
  let node: NodeSnapshot
  let model: TranscriptModel

  var body: some View {
    let artifact = node.output == .artifact
    Button {
      model.open(node.id)
    } label: {
      HStack(spacing: 14) {
        Image(systemName: node.icon.symbol)
          .frame(width: 40, height: 40)
          .background(.white.opacity(0.15), in: Circle())
        VStack(alignment: .leading, spacing: 2) {
          Text(artifact ? "Artifact" : "Skill").font(.caption.weight(.semibold)).opacity(0.75)
          Text(node.text).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: artifact ? "arrow.up.forward.square" : "square.and.arrow.down")
          .opacity(0.7)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: 420, alignment: .leading)
      .background(
        (artifact ? Color.accentColor : Color.purple).opacity(0.18),
        in: RoundedRectangle(cornerRadius: 16))
      .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
  }
}

/// Two or more activities none of which is important, behind one toggle.
/// Collapsed until opened, the state kept across a streamed delta by the
/// row's identity.
struct ActivityRunView: View {
  let nodes: [NodeSnapshot]
  let model: TranscriptModel
  @State private var open = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        open.toggle()
      } label: {
        Label(
          open ? "Collapse activities" : "Expand activities",
          systemImage: open ? "chevron.up" : "chevron.down"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      if open {
        ForEach(nodes, id: \.id) { NodeView(node: $0, model: model) }
          .transition(.opacity)
      }
    }
    // Here alone: a window-wide animation moved the scroll view and the
    // title bar's edge with it, and both flashed.
    .animation(.snappy(duration: 0.2), value: open)
  }
}
