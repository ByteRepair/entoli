import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WorkActivityBundle: WidgetBundle {
  var body: some Widget { WorkActivityWidget() }
}

/// Laid out as Android's turn notification reads: the app's name, what is
/// running, and Stop.
struct WorkActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: WorkAttributes.self) { context in
      HStack(spacing: 10) {
        AppMark(size: 36)
        VStack(alignment: .leading, spacing: 2) {
          Text("Entoli").font(.headline)
          Text(context.state.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 6) {
          Elapsed(since: context.attributes.started)
          if context.state.stoppable { StopButton() }
        }
      }
      .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        // Inset from the top corners, which the island's curve clips.
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            AppMark(size: 28)
            Text("Entoli").font(.headline)
          }
          .padding(.leading, 8)
          .padding(.top, 8)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Elapsed(since: context.attributes.started)
            .padding(.trailing, 8)
            .padding(.top, 8)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Text(context.state.summary)
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Spacer()
            if context.state.stoppable { StopButton().padding(.trailing, 8) }
          }
        }
      } compactLeading: {
        AppMark(size: 22)
      } compactTrailing: {
        Elapsed(since: context.attributes.started)
      } minimal: {
        AppMark(size: 22)
      }
    }
  }
}

/// The app icon as Icon Composer draws it: its foreground layer on the
/// icon's fill. The compiled icon is the app's alone, out of an extension's
/// reach, so the layer is this catalog's too, linked to the same file.
private struct AppMark: View {
  static let fill = Color(red: 0.30980, green: 0.27451, blue: 0.89804)

  let size: CGFloat

  var body: some View {
    Image("AppMark")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .background(Self.fill, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
  }
}

private struct Elapsed: View {
  let since: Date

  var body: some View {
    Text(since, style: .timer)
      .font(.subheadline)
      .monospacedDigit()
      .multilineTextAlignment(.trailing)
      .frame(maxWidth: 56)
  }
}

/// Android's notification action: a plain labelled button.
private struct StopButton: View {
  var body: some View {
    Button(intent: StopWorkIntent()) {
      Text("Stop").font(.subheadline.weight(.semibold))
    }
    // Filled: the icon's purple as text is unreadable on the island's black.
    .buttonStyle(.borderedProminent)
    .tint(AppMark.fill)
  }
}
