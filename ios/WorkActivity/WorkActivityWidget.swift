import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WorkActivityBundle: WidgetBundle {
  var body: some Widget { WorkActivityWidget() }
}

struct WorkActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: WorkAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: "ellipsis.bubble.fill")
          .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text("Entoli").font(.headline)
          Text(context.state.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Elapsed(since: context.attributes.started)
        if context.state.turns > 0 { StopButton() }
      }
      .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "ellipsis.bubble.fill").font(.title2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Elapsed(since: context.attributes.started)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Text(context.state.summary)
            Spacer()
            if context.state.turns > 0 { StopButton() }
          }
        }
      } compactLeading: {
        Image(systemName: "ellipsis.bubble.fill")
      } compactTrailing: {
        Elapsed(since: context.attributes.started)
      } minimal: {
        Image(systemName: "ellipsis.bubble.fill")
      }
    }
  }
}

private struct Elapsed: View {
  let since: Date

  var body: some View {
    Text(since, style: .timer)
      .monospacedDigit()
      .multilineTextAlignment(.trailing)
      .frame(maxWidth: 56)
  }
}

private struct StopButton: View {
  var body: some View {
    Button(intent: StopWorkIntent()) {
      Image(systemName: "stop.fill")
    }
    .tint(.red)
    .accessibilityLabel("Stop")
  }
}
