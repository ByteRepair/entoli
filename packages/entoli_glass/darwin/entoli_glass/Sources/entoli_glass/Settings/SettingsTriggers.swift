import SwiftUI

/// The triggers as cards of glass: what each fires on, what it says, when it
/// fires next, and the switch that arms it. A card opens the trigger's form;
/// a new one starts from the same form.
struct TriggersView: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var editing: CollectionRow.Editing?
  @StateObject private var acting = ItemActing()

  var body: some View {
    let items = row.items.compactMap { $0 }
    VStack(spacing: 12) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        card(item, index)
      }
      if let add = row.addLabel {
        Button {
          editing = CollectionRow.Editing(index: nil)
        } label: {
          // A list row tints its images with the accent, which on the
          // prominent button is the button itself.
          Label(add, systemImage: "plus")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .glassButton(prominent: true)
      }
    }
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    .sheet(item: $editing) { editing in
      FormSheet(model: model, id: row.id, index: editing.index)
    }
    .asking($acting.confirm, $acting.notice) { acting.agreed(model, row.id) }
  }

  private func card(_ item: SettingItemData, _ index: Int) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: item.icon?.symbol ?? "bolt")
        .font(.title2)
        .foregroundStyle(item.on == true ? Color.accentColor : .secondary)
        .frame(width: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.headline).lineLimit(1)
        if let subtitle = item.subtitle, !subtitle.isEmpty {
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      Toggle(
        "", isOn: Binding(get: { item.on ?? false }, set: { _ in acting.run(model, row.id, index, "toggle") })
      )
      .labelsHidden()
    }
    .padding(14)
    .contentShape(RoundedRectangle(cornerRadius: 20))
    .glassSurface(RoundedRectangle(cornerRadius: 20))
    #if os(iOS)
      .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20))
    #endif
    .onTapGesture { editing = CollectionRow.Editing(index: index) }
    .contextMenu {
      ForEach(item.actions.compactMap { $0 }, id: \.id) { action in
        Button(action.label, role: action.destructive ? .destructive : nil) {
          acting.act(model, row.id, index, action)
        }
      }
    }
  }
}
