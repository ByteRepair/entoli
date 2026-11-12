import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

extension ComposerTrigger {
  /// What is typed to open its menu.
  var glyph: String { self == .agent ? "@" : "/" }
}

extension NewChatSnapshot {
  static let initial = NewChatSnapshot(
    present: false, question: "", projects: [], devices: [], starters: [],
    showStarters: false, starting: false)

  func isSelected(_ choice: ProjectChoice) -> Bool {
    selected?.device == choice.device && selected?.project == choice.project
  }
}

/// The new-chat screen: Athena, the question, the projects as badges to pick
/// where the next chat goes, and a starter per `/skill` and `@agent` — the
/// only place those are named before their trigger is typed, while "Show
/// Command Chips in start page" is on. Dart's `ShellNewChat` says what is
/// there; a badge or a starter is an intent.
struct NewChatView: View {
  var model: ShellModel

  private var state: NewChatSnapshot { model.newChat }
  private var say: NewChatIntents { model.say.newChat }

  var body: some View {
    if state.starting {
      ProgressView().controlSize(.large)
    } else {
      // Right above the composer, and like it padding the page rather than
      // ending it: the page scrolls on beneath both, seen through the glass.
      page.safeAreaInset(edge: .bottom, spacing: 0) {
        Text("Type / for commands, @ for agents.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
      }
    }
  }

  private var page: some View {
    ScrollView {
      VStack(spacing: 18) {
        if let image = state.image.flatMap(flutterAsset) {
          image
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 240)
            // The feet fade into the page, so the figure stands on the
            // question rather than ending above it.
            .mask(
              LinearGradient(
                stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom))
            .accessibilityLabel("Athena")
        }
        // One slot for both questions, so the old one lifts away over the
        // new one arriving rather than the two stacking for the length of it.
        ZStack {
          if !state.question.isEmpty {
            Text(state.question)
              .font(.title3.weight(.semibold))
              .multilineTextAlignment(.center)
              .id(state.question)
              .transition(.asymmetric(insertion: .opacity, removal: .lift))
          }
        }
        .animation(.easeOut(duration: 0.35), value: state.question)
        FlowLayout(spacing: 8) {
          ForEach(state.projects, id: \.self) { badge($0) }
        }
        ForEach(state.devices, id: \.self) { device in
          VStack(spacing: 8) {
            HStack {
              line
              Text(device.offline ? "\(device.name) · offline" : device.name)
                .font(.caption)
                .foregroundStyle(.secondary)
              line
            }
            FlowLayout(spacing: 8) {
              ForEach(device.projects, id: \.self) { badge($0) }
            }
          }
        }
        if state.showStarters { starters }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 32)
      .frame(maxWidth: ShellView.readableWidth)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    // A drag through the page takes the keyboard down, as one back through
    // the conversation does.
    .scrollDismissesKeyboard(.immediately)
    .clearUnderComposer()
    .animation(ComposerView.motion, value: state)
  }

  private var line: some View {
    Rectangle().fill(.quaternary).frame(height: 1)
  }

  private var starters: some View {
    FlowLayout(spacing: 8) {
      ForEach(state.starters, id: \.self) { starter in
        Button {
          say.starter(trigger: starter.trigger, name: starter.name) { _ in }
        } label: {
          Text("\(starter.trigger.glyph)\(starter.name)").font(.callout.monospaced())
        }
        .glassButton()
        .help(starter.detail ?? "")
      }
    }
  }

  private func badge(_ choice: ProjectChoice) -> some View {
    let picked = state.isSelected(choice)
    return Button {
      say.pick(device: choice.device, project: choice.project) { _ in }
    } label: {
      HStack(spacing: 6) {
        if picked {
          Image(systemName: "checkmark")
        } else if let glyph = choice.glyph {
          Image(systemName: glyph.systemImage)
        }
        Text(choice.label).italic(choice.omada)
      }
    }
    .glassButton(prominent: picked)
  }
}

/// A Flutter asset out of the app's own bundle: `App.framework` keeps them
/// under `flutter_assets`. Read and decoded once, not on every body.
@MainActor
private func flutterAsset(_ key: String) -> Image? {
  if let image = flutterAssets[key] { return image }
  #if os(iOS)
    let base = Bundle.main.bundleURL.appendingPathComponent("Frameworks/App.framework/flutter_assets")
    guard let image = UIImage(contentsOfFile: base.appendingPathComponent(key).path) else { return nil }
    let read = Image(uiImage: image)
  #else
    let base = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Frameworks/App.framework/Resources/flutter_assets")
    guard let image = NSImage(contentsOf: base.appendingPathComponent(key)) else { return nil }
    let read = Image(nsImage: image)
  #endif
  flutterAssets[key] = read
  return read
}

@MainActor private var flutterAssets: [String: Image] = [:]

/// Rows of whatever fits, wrapping to the next as a chip row does: centred,
/// or from the leading edge where [centred] is false.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var centred = true

  private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
    var rows: [[(Int, CGSize)]] = [[]]
    var x: CGFloat = 0
    for (i, view) in subviews.enumerated() {
      let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if x > 0 && x + size.width > width {
        rows.append([])
        x = 0
      }
      rows[rows.count - 1].append((i, size))
      x += size.width + spacing
    }
    return rows
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let rows = rows(subviews, width: width)
    let height = rows.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +)
      + spacing * CGFloat(max(rows.count - 1, 0))
    let widest = rows.map { row in
      row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
    }.max() ?? 0
    return CGSize(width: proposal.width ?? widest, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(subviews, width: bounds.width) {
      let width = row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
      let height = row.map(\.1.height).max() ?? 0
      var x = bounds.minX + (centred ? (bounds.width - width) / 2 : 0)
      for (i, size) in row {
        subviews[i].place(
          at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += height + spacing
    }
  }
}

/// The old question going: blurring and growing as it fades, so it reads as
/// lifting off the glass rather than dissolving into it.
private struct Lift: ViewModifier {
  let gone: Bool

  func body(content: Content) -> some View {
    content
      .blur(radius: gone ? 10 : 0)
      .scaleEffect(gone ? 1.2 : 1)
      .opacity(gone ? 0 : 1)
  }
}

extension AnyTransition {
  fileprivate static var lift: AnyTransition {
    .modifier(active: Lift(gone: true), identity: Lift(gone: false))
  }
}
