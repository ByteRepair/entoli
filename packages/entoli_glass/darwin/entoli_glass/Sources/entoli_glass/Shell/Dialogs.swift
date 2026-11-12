import SwiftUI

/// The dialog Dart asked, as the platform's own alert: something to say, a
/// yes or no, text typed into the alert's fields, or a choice from a list.
/// Answered once, whichever way it goes.
struct DialogPresenter: ViewModifier {
  @Bindable var model: ShellModel

  @State private var text = ""
  @State private var second = ""

  private var request: DialogRequest? { model.dialog }

  private var alertShown: Binding<Bool> {
    Binding(
      get: { request.map { $0.kind != .choice } ?? false },
      set: { if !$0 { dismiss() } })
  }

  private var choiceShown: Binding<Bool> {
    Binding(
      get: { request?.kind == .choice },
      set: { if !$0 { dismiss() } })
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: request?.title, initial: true) {
        text = request?.initial ?? ""
        second = request?.secondInitial ?? ""
      }
      .alert(request?.title ?? "", isPresented: alertShown) {
        if let ask = request { actions(ask) }
      } message: {
        if let message = request?.message { Text(message) }
      }
      .confirmationDialog(
        request?.title ?? "", isPresented: choiceShown, titleVisibility: .visible
      ) {
        if let ask = request {
          ForEach(Array(ask.choices.enumerated()), id: \.offset) { index, choice in
            Button(Int64(index) == ask.picked ? "\(choice) ✓" : choice) {
              agree(choice: Int64(index))
            }
          }
        }
        Button("Cancel", role: .cancel) { dismiss() }
      }
  }

  @ViewBuilder private func actions(_ ask: DialogRequest) -> some View {
        switch ask.kind {
        case .text:
          if ask.lines > 1 {
            TextField(ask.hint ?? "", text: $text, axis: .vertical)
              .lineLimit(Int(ask.lines))
          } else {
            TextField(ask.hint ?? "", text: $text)
          }
          Button("Cancel", role: .cancel) { dismiss() }
          Button(ask.confirmLabel ?? "OK") { agree(text: text) }
            .disabled(!ask.allowBlank && text.trimmingCharacters(in: .whitespaces).isEmpty)
        case .pair:
          TextField(ask.label ?? "", text: $text)
          TextField(ask.secondLabel ?? "", text: $second)
          Button("Cancel", role: .cancel) { dismiss() }
          Button(ask.confirmLabel ?? "Save") { agree(text: text, second: second) }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        case .confirm:
          if let label = ask.confirmLabel {
            Button(label, role: ask.destructive ? .destructive : nil) { agree() }
            Button(ask.cancelLabel ?? "Cancel", role: .cancel) { dismiss() }
          } else {
            Button(ask.cancelLabel ?? "OK", role: .cancel) { dismiss() }
          }
        case .tell, .choice:
          Button("OK", role: .cancel) { agree() }
        }
  }

  private func agree(text: String? = nil, second: String? = nil, choice: Int64? = nil) {
    model.answer(DialogAnswer(agreed: true, text: text, second: second, choice: choice))
  }

  private func dismiss() {
    guard model.dialog != nil else { return }
    model.answer(DialogAnswer(agreed: false))
  }
}
