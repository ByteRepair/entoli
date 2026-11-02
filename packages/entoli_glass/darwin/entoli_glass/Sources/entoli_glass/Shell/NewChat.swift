import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// `NewChatSnapshot`.
struct NewChatState: Decodable, Equatable {
  struct Device: Decodable, Equatable, Hashable {
    var name: String
    var offline: Bool
    var projects: [ProjectChoice]
  }

  struct Selected: Decodable, Equatable {
    var device: String?
    var project: String?
  }

  struct Starter: Decodable, Equatable, Hashable {
    var trigger: String
    var name: String
    var description: String?
  }

  var present = false
  var question = ""
  var image: String?
  var projects: [ProjectChoice] = []
  var devices: [Device] = []
  var selected: Selected?
  var starters: [Starter] = []
  var starting = false

  func isSelected(_ choice: ProjectChoice) -> Bool {
    selected?.device == choice.device && selected?.project == choice.project
  }
}

/// The new-chat screen: Athena, the question, the projects as badges to pick
/// where the next chat goes, and a starter per `/skill` and `@agent` — the
/// only place those are named before their trigger is typed. Dart's
/// `ShellNewChat` says what is there; a badge or a starter is an intent.
struct NewChatView: View {
  @ObservedObject var model: ShellModel

  private var state: NewChatState { model.newChat }

  private func say(_ name: String, _ args: [String: Any?]) {
    model.intent("newChatScreen", ["name": name, "args": args.mapValues { $0 ?? NSNull() }])
  }

  var body: some View {
    if state.starting {
      ProgressView().controlSize(.large)
    } else {
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
          if !state.question.isEmpty {
            Text(state.question)
              .font(.title3.weight(.semibold))
              .multilineTextAlignment(.center)
              .contentTransition(.interpolate)
          }
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
          if state.starters.isEmpty {
            Text("Type / for commands, @ for agents.")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            FlowLayout(spacing: 8) {
              ForEach(state.starters.prefix(6), id: \.self) { starter in
                Button {
                  say("starter", ["trigger": starter.trigger, "name": starter.name])
                } label: {
                  Text("\(starter.trigger)\(starter.name)").font(.callout.monospaced())
                }
                .glassButton()
                .help(starter.description ?? "")
              }
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: ShellView.readableWidth)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      .animation(ComposerView.motion, value: state)
    }
  }

  private var line: some View {
    Rectangle().fill(.quaternary).frame(height: 1)
  }

  private func badge(_ choice: ProjectChoice) -> some View {
    let picked = state.isSelected(choice)
    return Button {
      say("pick", ["device": choice.device, "project": choice.project])
    } label: {
      HStack(spacing: 6) {
        if picked {
          Image(systemName: "checkmark")
        } else if !choice.symbol.isEmpty {
          Image(systemName: choice.symbol)
        }
        Text(choice.label).italic(choice.omada)
      }
    }
    .glassButton(prominent: picked)
  }
}

/// A Flutter asset out of the app's own bundle: `App.framework` keeps them
/// under `flutter_assets`.
private func flutterAsset(_ key: String) -> Image? {
  #if os(iOS)
    let base = Bundle.main.bundleURL.appendingPathComponent("Frameworks/App.framework/flutter_assets")
    guard let image = UIImage(contentsOfFile: base.appendingPathComponent(key).path) else { return nil }
    return Image(uiImage: image)
  #else
    let base = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Frameworks/App.framework/Resources/flutter_assets")
    guard let image = NSImage(contentsOf: base.appendingPathComponent(key)) else { return nil }
    return Image(nsImage: image)
  #endif
}

/// Rows of whatever fits, centred, wrapping to the next as a chip row does.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
    var rows: [[(Int, CGSize)]] = [[]]
    var x: CGFloat = 0
    for (i, view) in subviews.enumerated() {
      let size = view.sizeThatFits(.unspecified)
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
      var x = bounds.minX + (bounds.width - width) / 2
      for (i, size) in row {
        subviews[i].place(
          at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += height + spacing
    }
  }
}
