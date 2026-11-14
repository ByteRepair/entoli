import SwiftUI

extension TurnSnapshot {
  static let initial = TurnSnapshot(running: [], steers: [], withdrawable: false, approvals: [])

  var isEmpty: Bool {
    goal == nil && todo == nil && resume == nil && running.isEmpty && steers.isEmpty
      && approvals.isEmpty && question == nil
  }
}

extension RunningSnapshot: Identifiable {}
extension SteerSnapshot: Identifiable {}
extension ApprovalSnapshot: Identifiable {}

/// What a running turn puts above the composer, in the system's glass: the
/// offer to carry on an interrupted turn, the chat's goal, what is running, the says the turn
/// has not read yet, and the calls waiting on an answer. Dart's
/// `ShellTurnSurface` says what is there and runs what is pressed.
struct TurnSurfaceView: View {
  var model: ShellModel

  /// Which groups of pills are open: the strip's own, as it is in Flutter.
  @State private var open: Set<String> = []

  private var turn: TurnSnapshot { model.turn }
  private var say: TurnIntents { model.say.turn }

  var body: some View {
    VStack(spacing: 6) {
      if let resume = turn.resume { resumeRow(resume) }
      if let goal = turn.goal { goalRow(goal) }
      if let todo = turn.todo { todoRow(todo) }
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

  /// The backend's notice where it gave one, else how long ago the turn
  /// stopped.
  private func resumeRow(_ resume: ResumeSnapshot) -> some View {
    let started = Date(timeIntervalSince1970: Double(resume.startedAt) / 1000)
    return HStack(spacing: 8) {
      Image(systemName: "pause.circle").foregroundStyle(.secondary)
      Group {
        if let notice = resume.notice {
          Text(notice)
        } else {
          Text("Unfinished turn from \(started, format: .relative(presentation: .named))")
        }
      }
      .font(.callout).lineLimit(1)
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

  // MARK: Goal

  /// The chat's goal, as Flutter's `GoalStrip` draws it: where it stands,
  /// what it is, and its pause or resume and its clear, each sent back as the
  /// `/goal` command it is.
  private func goalRow(_ goal: GoalSnapshot) -> some View {
    let (symbol, tint): (String, Color) =
      switch goal.phase {
      case .active: ("scope", .accentColor)
      case .paused: ("pause.circle", .secondary)
      case .met: ("checkmark.circle", .accentColor)
      case .blocked: ("nosign", .red)
      }
    return HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(tint)
      (Text(goal.label + "  ").foregroundStyle(.secondary) + Text(goal.objective))
        .font(.callout)
        .lineLimit(1)
      Spacer(minLength: 4)
      if goal.phase == .active {
        Button {
          say.goal(action: .pause) { _ in }
        } label: {
          Image(systemName: "pause.fill")
        }
        .buttonStyle(.borderless)
        .help("Pause the goal")
      } else if goal.phase != .met {
        Button {
          say.goal(action: .resume) { _ in }
        } label: {
          Image(systemName: "play.fill")
        }
        .buttonStyle(.borderless)
        .help("Resume the goal")
      }
      Button {
        say.goal(action: .clear) { _ in }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Clear the goal")
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 34)
    .glassSurface(Capsule())
    .help([goal.label + ": " + goal.objective, goal.reason].compactMap { $0 }.joined(separator: " · "))
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  // MARK: Task list

  /// The task list's place in [open], beside the pill groups' kinds.
  private static let todoKey = "todo list"

  /// The latest turn's task list, as Flutter's `TodoStrip` draws it: how
  /// far it is and the task under way, opening to every task.
  private func todoRow(_ todo: TodoSnapshot) -> some View {
    let finished = todo.done == todo.items.count
    let todoOpen = open.contains(Self.todoKey)
    return VStack(alignment: .leading, spacing: 4) {
      Button {
        if todoOpen { open.remove(Self.todoKey) } else { open.insert(Self.todoKey) }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: finished ? "checkmark.circle" : Glyph.checklist.systemImage)
            .foregroundStyle(Color.accentColor)
          (Text("\(todo.done)/\(todo.items.count)  ").foregroundStyle(.secondary)
            + Text(todo.headline))
            .font(.callout)
            .lineLimit(1)
          Spacer(minLength: 4)
          Image(systemName: todoOpen ? "chevron.down" : "chevron.up")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(todoOpen ? "Hide the tasks" : "Show the tasks")
      if todoOpen {
        ForEach(Array(todo.items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.phase.symbol)
              .foregroundStyle(item.phase.tint)
              .accessibilityLabel(item.phase.spoken)
            Text(item.content)
              .font(.callout)
              .fontWeight(item.phase == .inProgress ? .semibold : nil)
              .foregroundStyle(item.phase == .completed ? .secondary : .primary)
          }
        }
        .padding(.bottom, 8)
      }
    }
    .padding(.horizontal, 14)
    .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
          .font(thing.kind == .job ? .callout.monospaced() : .callout)
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
        Image(systemName: approval.glyph.systemImage)
          .font(.callout)
          .frame(width: 28, height: 28)
          .background(.tint.opacity(0.2), in: Circle())
        Text(approval.title).font(.headline)
        Spacer(minLength: 8)
        Text(approval.tool).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      if let purpose = approval.purpose {
        Text(purpose).font(.callout).foregroundStyle(.secondary)
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
      // A row of buttons does not shrink, so on a phone the four in one row
      // would widen the card past the screen: the "Always" pair moves up.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          denyButton(approval)
          alwaysButtons(approval)
          allowButton(approval)
        }
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 8) { alwaysButtons(approval) }
          HStack(spacing: 8) {
            denyButton(approval)
            allowButton(approval)
          }
        }
        VStack(alignment: .trailing, spacing: 8) {
          denyButton(approval)
          alwaysButtons(approval)
          allowButton(approval)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(14)
    .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private func denyButton(_ approval: ApprovalSnapshot) -> some View {
    Button("Deny", role: .destructive) { answer(approval, .deny) }
      .glassButton()
  }

  @ViewBuilder private func alwaysButtons(_ approval: ApprovalSnapshot) -> some View {
    if approval.chat {
      Button("Always in Chat") { answer(approval, .chat) }.glassButton()
    }
    if approval.project {
      Button("Always in Project") { answer(approval, .project) }.glassButton()
    }
  }

  @ViewBuilder private func allowButton(_ approval: ApprovalSnapshot) -> some View {
    if approval.allow {
      // No Return shortcut: the window would take Return for it before
      // the composer's field heard it.
      Button("Allow") { answer(approval, .allow) }
        .glassButton(prominent: true)
    }
  }

  private func answer(_ approval: ApprovalSnapshot, _ answer: ApprovalAnswer) {
    say.approve(id: approval.id, answer: answer) { _ in }
  }
}

/// This frontend's words for the turn's state.
extension GoalSnapshot {
  var label: String {
    switch phase {
    case .active: "Goal active"
    case .paused: "Goal paused"
    case .met: "Goal met"
    case .blocked: "Goal blocked"
    }
  }
}

extension TodoPhase {
  /// The plan page's pictures for the same three states.
  var symbol: String {
    switch self {
    case .completed: SettingIcon.taskDone.symbol
    case .inProgress: SettingIcon.taskActive.symbol
    case .pending: SettingIcon.taskPending.symbol
    }
  }

  var tint: Color {
    switch self {
    case .completed: .accentColor
    case .inProgress: .orange
    case .pending: .secondary
    }
  }

  var spoken: String {
    switch self {
    case .completed: "Done"
    case .inProgress: "In progress"
    case .pending: "To do"
    }
  }
}

extension RunningSnapshot {
  /// The pill's words: the browser's page, the job's command, the
  /// sub-agent's handle.
  var label: String {
    switch kind {
    case .browser: hidden ? "Browser · \(name) · hidden from the agent" : "Browser · \(name)"
    case .job: name
    case .subAgent: "@\(name)"
    }
  }

  var tooltip: String {
    switch kind {
    case .browser: "Watch the agent's browser"
    case .job: "Background job"
    case .subAgent: "Sub-agent @\(name)"
    }
  }

  /// What it is gathered under with the rest of its kind; none standing
  /// alone, ahead of the groups.
  var group: String? {
    switch kind {
    case .browser: nil
    case .job: "background task"
    case .subAgent: "sub-agent"
    }
  }

  /// In place of the spinner.
  var symbol: String? {
    switch kind {
    case .browser: (hidden ? Glyph.hidden : Glyph.browse).systemImage
    case .job, .subAgent: nil
    }
  }
}

extension SteerSnapshot {
  /// What was said, or the files it carried where it said nothing.
  var line: String {
    text.isEmpty ? files.joined(separator: ", ") : text.replacingOccurrences(of: "\n", with: " ")
  }
}
