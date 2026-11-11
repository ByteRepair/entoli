import SwiftUI

/// The triggers as cards of glass: what each fires on, what it says, when it
/// fires next, and the switch that arms it. A card opens the trigger's form;
/// a new one starts from the same form.
struct TriggersView: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var editing: CollectionRow.Editing?
  @State private var deleting: (Int, SettingItemActionData)?
  @State private var notice: SettingNoticeData?

  var body: some View {
    let items = row.items.compactMap { $0 }
    VStack(spacing: 12) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        card(item, index)
      }
      Button {
        editing = CollectionRow.Editing(index: nil)
      } label: {
        // A list row tints its images with the accent, which on the
        // prominent button is the button itself.
        Label(row.addLabel ?? "Add trigger", systemImage: "plus")
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .glassButton(prominent: true)
    }
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    .sheet(item: $editing) { editing in
      FormSheet(model: model, id: row.id, index: editing.index)
    }
    .alert(
      deleting?.1.confirm?.title ?? "",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { pending in
      Button(pending.1.confirm?.confirmLabel ?? "Delete", role: .destructive) {
        act(pending.0, pending.1.id)
      }
      Button("Cancel", role: .cancel) {}
    } message: { pending in
      Text(pending.1.confirm?.message ?? "")
    }
    .alert(
      notice?.message ?? "",
      isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
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
        "", isOn: Binding(get: { item.on ?? false }, set: { _ in act(index, "toggle") })
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
          if action.confirm != nil { deleting = (index, action) } else { act(index, action.id) }
        }
      }
    }
  }

  private func act(_ index: Int, _ action: String) {
    Task { @MainActor in notice = await model.itemAction(row.id, index, action) }
  }
}
