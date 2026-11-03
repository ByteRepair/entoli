import SwiftUI

extension TurnSnapshot {
  static let initial = TurnSnapshot(running: [], steers: [], withdrawable: false, approvals: [])

  var isEmpty: Bool {
    resume == nil && running.isEmpty && steers.isEmpty && approvals.isEmpty
      && question == nil
  }
}

extension RunningSnapshot: Identifiable {}
extension SteerSnapshot: Identifiable {}
extension ApprovalSnapshot: Identifiable {}

/// What a running turn puts above the composer, in the system's glass: the
/// offer to carry on an interrupted turn, what is running, the says the turn
/// has not read yet, and the calls waiting on an answer. Dart's
/// `ShellTurnSurface` says what is there and runs what is pressed.
struct TurnSurfaceView: View {
  @ObservedObject var model: ShellModel

  /// Which groups of pills are open: the strip's own, as it is in Flutter.
  @State private var open: Set<String> = []

  private var turn: TurnSnapshot { model.turn }
  private var say: TurnIntents { model.say.turn }

  var body: some View {
    VStack(spacing: 6) {
      if let resume = turn.resume { resumeRow(resume) }
      if !turn.running.isEmpty { runningRow }
      if !turn.steers.isEmpty { steerCard }
      ForEach(turn.approvals) { approvalCard($0) }
      if let asked = turn.question {
        QuestionPanel(asked: asked) { answers in
          say.answer(id: asked.id, answers: answers) { _ in }
        }
        // A new request starts again: what was picked was for the last one.
        .id(asked.id)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .padding(.horizontal, 8)
    .animation(ComposerView.motion, value: turn)
    .animation(ComposerView.motion, value: open)
  }

  // MARK: Resume

  private func resumeRow(_ text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "pause.circle").foregroundStyle(.secondary)
      Text(text).font(.callout).lineLimit(1)
      Spacer(minLength: 8)
      Button {
        say.resume { _ in }
      } label: {
        Label("Continue", systemImage: "play.fill")
      }
      .glassButton(prominent: true)
    }
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .padding(.vertical, 6)
    .glassSurface(Capsule())
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  // MARK: Running

  private var runningRow: some View {
    let alone = turn.running.filter { $0.group == nil }
    let groups = Dictionary(grouping: turn.running.filter { $0.group != nil }) { $0.group! }
    let kinds = turn.running.compactMap(\.group).reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(alone) { pill($0) }
        ForEach(kinds, id: \.self) { kind in
          let things = groups[kind] ?? []
          HStack(spacing: 6) {
            Button {
              if open.contains(kind) { open.remove(kind) } else { open.insert(kind) }
            } label: {
              HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(things.count) \(things.count == 1 ? kind : kind + "s") running")
                Image(systemName: open.contains(kind) ? "chevron.left" : "chevron.right")
                  .font(.caption2)
              }
              .font(.callout)
              .padding(.horizontal, 12)
              .frame(height: 30)
              .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if open.contains(kind) {
              ForEach(things) { pill($0).transition(.move(edge: .leading).combined(with: .opacity)) }
            }
          }
          .glassSurface(Capsule())
        }
      }
      .padding(.vertical, 2)
    }
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private func pill(_ thing: RunningSnapshot) -> some View {
    Button {
      say.running(id: thing.id) { _ in }
    } label: {
      HStack(spacing: 6) {
        if let symbol = thing.symbol {
          Image(systemName: symbol)
        } else {
          ProgressView().controlSize(.mini)
        }
        Text(thing.label)
          .font(thing.mono ? .callout.monospaced() : .callout)
          .lineLimit(1)
      }
      .padding(.horizontal, 12)
      .frame(height: 30)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassSurface(Capsule())
    .help(thing.tooltip)
  }

  // MARK: Steers

  private var steerCard: some View {
    VStack(spacing: 2) {
      ForEach(turn.steers) { steer in
        HStack(spacing: 8) {
          Image(systemName: "arrow.turn.down.right").foregroundStyle(.tint)
          (Text(steer.line) + Text("  at the next step").foregroundStyle(.secondary))
            .font(.callout)
            .lineLimit(1)
          Spacer(minLength: 4)
          Button {
            say.queueSteer(id: steer.id) { _ in }
          } label: {
            Image(systemName: "clock")
          }
          .buttonStyle(.borderless)
          .help("Send after this turn instead")
          if turn.withdrawable {
            Button {
              say.withdraw(id: steer.id) { _ in }
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Take back")
          }
        }
        .frame(minHeight: 28)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  // MARK: Approvals

  private func approvalCard(_ approval: ApprovalSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: approval.symbol)
          .font(.callout)
          .frame(width: 28, height: 28)
          .background(.tint.opacity(0.2), in: Circle())
        Text(approval.title).font(.headline)
        Spacer(minLength: 8)
        Text(approval.tool).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      if let detail = approval.detail {
        ScrollView {
          Text(detail)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 132)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Deny", role: .destructive) { answer(approval, .deny) }
          .glassButton()
        if approval.chat {
          Button("Always in Chat") { answer(approval, .chat) }.glassButton()
        }
        if approval.project {
          Button("Always in Project") { answer(approval, .project) }.glassButton()
        }
        if approval.allow {
          // No Return shortcut: the window would take Return for it before
          // the composer's field heard it.
          Button("Allow") { answer(approval, .allow) }
            .glassButton(prominent: true)
        }
      }
    }
    .padding(14)
    .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private func answer(_ approval: ApprovalSnapshot, _ answer: ApprovalAnswer) {
    say.approve(id: approval.id, answer: answer) { _ in }
  }
}
