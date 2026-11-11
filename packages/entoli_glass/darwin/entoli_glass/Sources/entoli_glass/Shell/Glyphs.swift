/// This frontend's picture for each glyph the app names: Apple's own symbols.
/// Exhaustive, so a glyph added to the contract does not compile here until
/// it has one.
extension Glyph {
  var systemImage: String {
    switch self {
    case .add: "plus"
    case .check: "checkmark"
    case .checklist: "checklist"
    case .close: "xmark"
    case .copy: "doc.on.doc"
    case .newFolder: "folder.badge.plus"
    case .delete: "trash"
    case .edit: "pencil"
    case .filter: "line.3.horizontal.decrease"
    case .textSize: "textformat.size"
    case .openInBrowser: "safari"
    case .openExternal: "arrow.up.forward.square"
    case .restart: "arrow.counterclockwise"
    case .save: "square.and.arrow.down"
    case .show: "eye"
    case .hidden: "eye.slash"
    case .more: "ellipsis.circle"
    case .terminal: "terminal"
    case .globe: "globe"
    case .browse: "safari"
    case .document: "doc.text"
    case .shield: "checkmark.shield"
    case .home: "house"
    case .folder: "folder"
    case .team: "person.3"
    case .remote: "laptopcomputer.and.iphone"
    case .info: "info.circle"
    case .tune: "slider.horizontal.3"
    }
  }
}
