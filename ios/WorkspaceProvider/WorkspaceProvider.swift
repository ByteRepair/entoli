import FileProvider
import Foundation

/// The workspaces in the Files app. See "The workspaces in the
/// Files app" in ios/AGENTS.md.
final class WorkspaceProvider: NSObject, NSFileProviderReplicatedExtension {
  private let domain: NSFileProviderDomain
  private let known = KnownFolders()

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    super.init()
  }

  func invalidate() {}

  private var tree: WorkspaceTree? { workspaceDataDir.map(WorkspaceTree.init) }

  func item(
    for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    do {
      completionHandler(try lookUp(identifier), nil)
    } catch {
      completionHandler(nil, error)
    }
    return Progress()
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    do {
      let item = try lookUp(itemIdentifier)
      guard let source = item.url, !item.isFolder,
        let temp = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
      else { throw noSuchItem }
      // A copy, which the system moves into place: a clone on APFS, so it
      // costs no space until the workspace file changes.
      let copy = temp.appendingPathComponent(UUID().uuidString)
      try FileManager.default.copyItem(at: source, to: copy)
      completionHandler(copy, item, nil)
    } catch {
      completionHandler(nil, nil, error)
    }
    return Progress()
  }

  func createItem(
    basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    do {
      // Above a workspace is the layout's, with no directory to add to.
      guard let tree, let parent = WorkspaceNode(itemTemplate.parentItemIdentifier),
        let node = parent.child(itemTemplate.filename)
      else { throw NSFileProviderError(.excludedFromSync) }
      let target = try tree.url(of: parent).appendingPathComponent(itemTemplate.filename)
      guard !FileManager.default.fileExists(atPath: target.path) else {
        throw NSFileProviderError(.filenameCollision)
      }
      if itemTemplate.contentType == .folder {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      } else if let url {
        try FileManager.default.copyItem(at: url, to: target)
      } else {
        FileManager.default.createFile(atPath: target.path, contents: nil)
      }
      completionHandler(try tree.item(for: node), [], false, nil)
    } catch {
      completionHandler(nil, [], false, error)
    }
    return Progress()
  }

  func modifyItem(
    _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields, contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    do {
      let current = try lookUp(item.itemIdentifier)
      if changedFields.contains(.contents), let newContents, let target = current.url {
        // Copied beside it and swapped in, since the system owns the file it
        // hands over.
        let staged = target.deletingLastPathComponent()
          .appendingPathComponent(".\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: newContents, to: staged)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
      }
      // Anything else, a last-used date or a tag, is the system's to keep.
      completionHandler(try lookUp(item.itemIdentifier), [], false, nil)
    } catch {
      completionHandler(nil, [], false, error)
    }
    return Progress()
  }

  func deleteItem(
    identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping (Error?) -> Void
  ) -> Progress {
    do {
      guard let tree, let node = WorkspaceNode(identifier), !node.isFixed else {
        throw NSFileProviderError(.deletionRejected)
      }
      try FileManager.default.removeItem(at: try tree.url(of: node))
      completionHandler(nil)
    } catch {
      completionHandler(error)
    }
    return Progress()
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    guard let tree else { throw noSuchItem }
    switch containerItemIdentifier {
    case .workingSet: return WorkingSet(tree: tree, known: known)
    case .trashContainer: return Folder(tree: tree, node: nil, known: known)
    default:
      guard let node = WorkspaceNode(containerItemIdentifier) else { throw noSuchItem }
      return Folder(tree: tree, node: node, known: known)
    }
  }

  private func lookUp(_ identifier: NSFileProviderItemIdentifier) throws -> WorkspaceItem {
    guard let tree, let node = WorkspaceNode(identifier), let item = try? tree.item(for: node)
    else { throw noSuchItem }
    return item
  }

  private var noSuchItem: Error { NSFileProviderError(.noSuchItem) }
}

/// A folder's listing. The trash is one with nothing in it.
private final class Folder: NSObject, NSFileProviderEnumerator {
  let tree: WorkspaceTree
  let node: WorkspaceNode?
  let known: KnownFolders

  init(tree: WorkspaceTree, node: WorkspaceNode?, known: KnownFolders) {
    self.tree = tree
    self.node = node
    self.known = known
  }

  func invalidate() {}

  func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    guard let node else { return observer.finishEnumerating(upTo: nil) }
    do {
      let children = try tree.children(of: node)
      known.saw(node, children)
      observer.didEnumerate(children)
      observer.finishEnumerating(upTo: nil)
    } catch {
      observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
    }
  }

  // Changes reach the system through the working set alone; a folder asked
  // anyway is listed again.
  func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    completionHandler(known.anchor)
  }
}

/// Every folder the system has listed, which is what it holds a copy of and
/// what has to be kept current.
private final class WorkingSet: NSObject, NSFileProviderEnumerator {
  let tree: WorkspaceTree
  let known: KnownFolders

  init(tree: WorkspaceTree, known: KnownFolders) {
    self.tree = tree
    self.known = known
  }

  func invalidate() {}

  func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    let items = known.refresh(tree).updated
    if !items.isEmpty { observer.didEnumerate(items) }
    observer.finishEnumerating(upTo: nil)
  }

  func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    let changes = known.refresh(tree, changedOnly: true)
    if !changes.deleted.isEmpty { observer.didDeleteItems(withIdentifiers: changes.deleted) }
    if !changes.updated.isEmpty { observer.didUpdate(changes.updated) }
    observer.finishEnumeratingChanges(upTo: known.anchor, moreComing: false)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    completionHandler(known.anchor)
  }
}

/// The folders the system has listed and what each held at the time, kept
/// in the extension's own container. Nothing tells the extension a workspace
/// changed — the app's commands write straight to the disk — so the working
/// set is a fresh listing of these, compared against the last.
private final class KnownFolders {
  private let lock = NSLock()
  private let file: URL? = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
    .appendingPathComponent("known-folders.json")

  /// Folder identifier to its children's identifiers and version keys.
  private var folders: [String: [String: String]] = [:]
  private var generation = 0

  init() {
    guard let file, let data = try? Data(contentsOf: file),
      let saved = try? JSONDecoder().decode(Saved.self, from: data)
    else { return }
    folders = saved.folders
    generation = saved.generation
  }

  var anchor: NSFileProviderSyncAnchor {
    lock.withLock { NSFileProviderSyncAnchor(Data(String(generation).utf8)) }
  }

  func saw(_ folder: WorkspaceNode, _ children: [WorkspaceItem]) {
    lock.withLock {
      folders[folder.identifier.rawValue] = Dictionary(
        children.map { ($0.itemIdentifier.rawValue, $0.versionKey) }, uniquingKeysWith: { a, _ in a })
      save()
    }
  }

  /// Every known folder listed again. A folder that is gone is dropped
  /// unreported, since its own deletion is its parent's change.
  func refresh(_ tree: WorkspaceTree, changedOnly: Bool = false)
    -> (updated: [WorkspaceItem], deleted: [NSFileProviderItemIdentifier])
  {
    lock.withLock {
      var updated: [WorkspaceItem] = []
      var deleted: [NSFileProviderItemIdentifier] = []
      for (id, before) in folders {
        guard let node = WorkspaceNode(.init(id)), let children = try? tree.children(of: node) else {
          folders[id] = nil
          continue
        }
        var now: [String: String] = [:]
        for child in children {
          let key = child.itemIdentifier.rawValue
          now[key] = child.versionKey
          if !changedOnly || before[key] != child.versionKey { updated.append(child) }
        }
        deleted += before.keys.filter { now[$0] == nil }.map { .init($0) }
        folders[id] = now
      }
      generation += 1
      save()
      return (updated, deleted)
    }
  }

  private struct Saved: Codable {
    var folders: [String: [String: String]]
    var generation: Int
  }

  private func save() {
    guard let file else { return }
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Saved(folders: folders, generation: generation)).write(to: file, options: .atomic)
  }
}
