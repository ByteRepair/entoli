import SwiftUI

extension MeterHueData {
  var colour: Color {
    switch self {
    case .grey: .gray
    case .orange: .orange
    case .green: .green
    case .purple: .purple
    case .blue: .blue
    }
  }
}

/// A meter of parts end to end — what fills a context window — with its
/// mark a line across it named over it, and a legend of the parts under it.
struct SegmentedMeter: View {
  let meter: SettingMeterData

  private static let height: CGFloat = 12

  var body: some View {
    let segments = meter.segments.compactMap { $0 }
    let used = segments.reduce(0) { $0 + $1.fraction }
    // Over the whole, the bar is full rather than overflowing.
    let scale = max(used, 1)
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { space in
        let width = space.size.width
        VStack(alignment: .leading, spacing: 4) {
          if let mark = meter.markFraction, let label = meter.markLabel {
            Text(label).font(.caption2).foregroundStyle(.secondary)
              .fixedSize()
              .alignmentGuide(.leading) { -(width - $0.width) * mark }
          }
          ZStack(alignment: .leading) {
            // Faint, so the grey segment still reads against it.
            Capsule().fill(Color.secondary.opacity(0.15))
            HStack(spacing: 0) {
              ForEach(Array(segments.enumerated()), id: \.offset) { _, part in
                Rectangle().fill(part.hue.colour)
                  .frame(width: width * part.fraction / scale)
                  .help("\(part.label): \(part.amount)")
              }
            }
            .clipShape(Capsule())
            if let mark = meter.markFraction {
              RoundedRectangle(cornerRadius: 1).fill(.primary)
                .frame(width: 2, height: Self.height + 8)
                .offset(x: width * mark - 1)
            }
          }
          .frame(height: Self.height)
        }
      }
      .frame(height: Self.height + (meter.markLabel == nil ? 4 : 22))
      Legend(segments: segments)
    }
    .accessibilityElement(children: .combine)
  }

  private struct Legend: View {
    let segments: [SettingMeterSegmentData]

    var body: some View {
      FlowLayout(spacing: 6, centred: false) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, part in
          HStack(spacing: 5) {
            Circle().fill(part.hue.colour).frame(width: 7, height: 7)
            Text(part.label).font(.caption)
            Text(part.amount).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

/// Prose the model reads, shown as it will be read, a tap opening its
/// editor page over this one: the instructions on the profile.
struct PromptRow: View {
  let model: SettingsModel
  let row: SettingRowData

  /// Tall enough to read what it says, short enough that a long one does
  /// not push the rest of its page out of sight.
  private static let preview: CGFloat = 320

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(row.title).font(.subheadline).foregroundStyle(.secondary)
      ActionPress(model: model, row: row) {
        Group {
          if let text = row.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DocumentMarkdown(text: text)
          } else {
            Text(row.prompt ?? "").foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: Self.preview, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: Self.preview, alignment: .top)
        .clipped()
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)
      .disabled(!row.enabled)
      ActionPress(model: model, row: row) {
        Label("Edit \(row.title.lowercased())", systemImage: "pencil")
      }
      .buttonStyle(.borderless)
      .disabled(!row.enabled)
    }
    .padding(.vertical, 4)
  }
}
