import SwiftUI

/// What stands where the composer does while the agent waits on an answer:
/// one question at a time, its options to click, a field for an answer of
/// one's own, and a bar of segments saying which this is and which are
/// answered. `QuestionPanel` in Flutter, drawn in the system's glass, with the
/// same rules: picking moves on but never sends, the segments go back to any
/// question, and the one button sends what is picked — `Skip` with nothing
/// picked, which is how a user with nothing to say gets the turn moving.
///
/// What is picked is this view's until Send, as a form's is.
struct QuestionPanel: View {
  let asked: TurnState.Asked
  let send: ([String?]) -> Void

  @State private var answers: [String?]
  @State private var typed: [String]
  @State private var at = 0

  init(asked: TurnState.Asked, send: @escaping ([String?]) -> Void) {
    self.asked = asked
    self.send = send
    _answers = State(initialValue: Array(repeating: nil, count: asked.questions.count))
    _typed = State(initialValue: Array(repeating: "", count: asked.questions.count))
  }

  private var questions: [TurnState.Question] { asked.questions }
  private var several: Bool { questions.count > 1 }

  /// The answer at [index] is the typed one rather than an option's.
  private func typedPicked(_ index: Int) -> Bool {
    guard let answer = answers[index] else { return false }
    return questions[index].options.allSatisfy { $0.answer != answer }
  }

  private func pick(_ option: TurnState.Option) {
    answers[at] = option.answer
    if at < questions.count - 1 { at += 1 }
  }

  private func type(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    answers[at] = trimmed.isEmpty ? nil : trimmed
  }

  var body: some View {
    let question = questions[at]
    VStack(alignment: .leading, spacing: 10) {
      if several {
        Text("Question \(at + 1) of \(questions.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
        segments
      }
      Text(question.question).font(.headline)
      if let summary = question.summary {
        Text(summary).font(.callout).foregroundStyle(.secondary)
      }
      // A long list scrolls inside the panel rather than pushing the
      // conversation off screen.
      ScrollView {
        VStack(spacing: 6) {
          ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
            optionRow(option)
          }
          typedRow
        }
      }
      .frame(maxHeight: 260)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        if several {
          Button {
            at -= 1
          } label: {
            Label("Back", systemImage: "chevron.left")
          }
          .disabled(at == 0)
          .buttonStyle(.borderless)
          Button {
            at += 1
          } label: {
            Label("Next", systemImage: "chevron.right").labelStyle(.titleAndIcon)
          }
          .disabled(at == questions.count - 1)
          .buttonStyle(.borderless)
        }
        Spacer()
        // One button, because there is one action: send what is picked.
        Button(answers.allSatisfy { $0 == nil } ? "Skip" : "Send") {
          send(answers)
        }
        .glassButton(prominent: true)
      }
    }
    .padding(14)
    .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .animation(ComposerView.motion, value: at)
    .animation(ComposerView.motion, value: answers)
  }

  /// One segment per question: filled once answered, taller under the one
  /// being asked. A click jumps to it.
  private var segments: some View {
    HStack(spacing: 4) {
      ForEach(questions.indices, id: \.self) { i in
        Button {
          at = i
        } label: {
          Capsule()
            .fill(answers[i] != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            .frame(height: i == at ? 6 : 3)
            .frame(maxWidth: .infinity, minHeight: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(questions[i].question)
      }
    }
  }

  private func optionRow(_ option: TurnState.Option) -> some View {
    let picked = answers[at] == option.answer
    return Button {
      pick(option)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(option.label).fontWeight(.semibold)
          if let detail = option.detail {
            Text(detail).font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if picked { Image(systemName: "checkmark").foregroundStyle(.tint) }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.6)),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  /// The last row of every question: an answer the user writes. Typing picks
  /// it, and a click on it picks again what it holds.
  private var typedRow: some View {
    let picked = typedPicked(at)
    let text = Binding(
      get: { typed[at] },
      set: {
        typed[at] = $0
        type($0)
      })
    return HStack(spacing: 8) {
      TextField("Something else — type your own answer", text: text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...4)
        .onSubmit {
          if at < questions.count - 1 { at += 1 }
        }
        .simultaneousGesture(TapGesture().onEnded { type(typed[at]) })
      if picked { Image(systemName: "checkmark").foregroundStyle(.tint) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.6)),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
