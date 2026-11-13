import FileProvider
import Foundation
import UniformTypeIdentifiers

// The workspaces as the Files app sees them, compiled into the Runner as well
// as the extension: the Runner names a folder by the same identifier when it
// opens Files at one. See "The workspaces in the Files app" in ios/AGENTS.md.
//
// Read with no Flutter engine running, so the layout `AppConfig` composes is
// read off the disk here, as Android's `WorkspaceProvider` reads it.

/// `iosAppGroup`, in lib/core/platform/host.dart.
let workspaceAppGroup = "group.io.byterepair.entoli"

/// "Local": this device's workspaces, which a domain per synced device's
/// could one day sit beside.
let workspaceDomain = NSFileProviderDomain(
  identifier: NSFileProviderDomainIdentifier("workspaces"), displayName: "Local Workspaces")

/// The data directory, inside the App Group's container.
let workspaceDataDir: URL? = FileManager.default
  .containerURL(forSecurityApplicationGroupIdentifier: workspaceAppGroup)?
  .appendingPathComponent("entoli", isDirectory: true)

/// A place in the tree, the disk's own layout: every project is the root, a
/// project is its workspace, and its `chats/` is a Chats folder whose
/// folders, one per chat, are named by the chat's title rather than its id.
enum WorkspaceNode: Equatable {
  case projects
  case project(String)
  case chats(project: String)
  case chat(project: String, id: String)
  /// Anything else in a workspace, as segments relative to the data
  /// directory.
  case path([String])

  // A project identifier is ":<name>"; anything else is a path relative to
  // the data directory, which always starts `projects`, so neither reads as
  // the other.
  private static let project = ":"

  /// `defaultProjectDir`, in lib/domain/project.dart.
  static let defaultProject = "default"

  /// The built-in projects whose workspace is not shared
  /// (lib/domain/builtin_project.dart), kept in step by hand as Android's
  /// `UNBROWSED` is: a chat that must not reach past itself is not one whose
  /// scratch the Files app browses.
  static let unbrowsed: Set<String> = ["anonymous"]

  /// `projects/<name>/workspace`, which every path starts with.
  static let workspaceDepth = 3

  /// Refuses what was never handed out: an identifier is composed by
  /// whoever asks, so `:..` or `projects/x/workspace/../../..` arrive too.
  init?(_ identifier: NSFileProviderItemIdentifier) {
    let raw = identifier.rawValue
    if identifier == .rootContainer {
      self = .projects
    } else if raw.hasPrefix(Self.project) {
      let name = String(raw.dropFirst(Self.project.count))
      guard Self.isProjectDir(name) else { return nil }
      self = .project(name)
    } else {
      let segments = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard segments.count > Self.workspaceDepth, segments[0] == "projects",
        Self.isProjectDir(segments[1]), segments[2] == "workspace",
        !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      else { return nil }
      self = Self.at(segments)
    }
  }

  /// The node a checked path names.
  private static func at(_ segments: [String]) -> WorkspaceNode {
    switch (segments.count - workspaceDepth, segments[workspaceDepth]) {
    case (1, "chats"): .chats(project: segments[1])
    case (2, "chats"): .chat(project: segments[1], id: segments[4])
    default: .path(segments)
    }
  }

  /// The node for [url], a folder the app has open: the nearest one the tree
  /// holds, or the root.
  static func of(_ url: URL, in dataDir: URL) -> WorkspaceNode {
    let base = dataDir.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(base) else { return .projects }
    var segments = path.dropFirst(base.count).split(separator: "/").map(String.init)
    while segments.count > workspaceDepth {
      if let node = WorkspaceNode(.init(segments.joined(separator: "/"))) { return node }
      segments.removeLast()
    }
    if segments.count >= 2, isProjectDir(segments[1]) { return .project(segments[1]) }
    return .projects
  }

  /// The directory on disk, relative to the data directory; nil for the
  /// root, which is every project rather than one.
  var segments: [String]? {
    switch self {
    case .projects: nil
    case .project(let name): ["projects", name, "workspace"]
    case .chats(let name): ["projects", name, "workspace", "chats"]
    case .chat(let name, let id): ["projects", name, "workspace", "chats", id]
    case .path(let segments): segments
    }
  }

  var identifier: NSFileProviderItemIdentifier {
    switch self {
    case .projects: .rootContainer
    case .project(let name): .init(Self.project + name)
    default: .init(segments!.joined(separator: "/"))
    }
  }

  var parent: WorkspaceNode {
    switch self {
    case .projects, .project: .projects
    case .chats(let name): .project(name)
    case .chat(let name, _): .chats(project: name)
    case .path(let segments):
      segments.count == Self.workspaceDepth + 1
        ? .project(segments[1]) : Self.at(Array(segments.dropLast()))
    }
  }

  /// A place the layout makes rather than the user, which Files may not
  /// delete.
  var isFixed: Bool {
    if case .path = self { return false }
    return true
  }

  /// Where a child named [name] would be, if this holds files at all. The
  /// Chats folder holds only the app's chats.
  func child(_ name: String) -> WorkspaceNode? {
    switch self {
    case .projects, .chats: return nil
    default:
      guard !name.contains("/") else { return nil }
      return WorkspaceNode(.init((segments! + [name]).joined(separator: "/")))
    }
  }

  // The shape rule, `isProjectDirName` in lib/domain/project.dart, bar
  // `default`, which is a directory like any other here.
  static func isProjectDir(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !unbrowsed.contains(name)
  }
}

/// Reads the tree off the disk.
struct WorkspaceTree {
  let dataDir: URL

  func item(for node: WorkspaceNode) throws -> WorkspaceItem {
    switch node {
    case .projects:
      return WorkspaceItem(node: node, name: workspaceDomain.displayName, url: nil)
    case .project(let name):
      return WorkspaceItem(node: node, name: projectLabel(name), url: nil)
    case .chat(let project, _):
      // Its name depends on its siblings'.
      guard let chat = try chats(project).first(where: { $0.node == node }) else {
        throw NSFileProviderError(.noSuchItem)
      }
      return chat
    case .chats, .path:
      let url = try resolve(node.segments!)
      return WorkspaceItem(node: node, name: name(of: node, url), url: url)
    }
  }

  func children(of node: WorkspaceNode) throws -> [WorkspaceItem] {
    switch node {
    case .projects:
      return projectDirs().map { WorkspaceItem(node: .project($0), name: projectLabel($0), url: nil) }
    case .chats(let project):
      return try chats(project)
    default:
      let segments = node.segments!
      return try listed(segments).compactMap { child in
        guard let node = WorkspaceNode(.init((segments + [child.lastPathComponent]).joined(separator: "/")))
        else { return nil }
        return WorkspaceItem(node: node, name: name(of: node, child), url: child)
      }
    }
  }

  func url(of node: WorkspaceNode) throws -> URL {
    guard let segments = node.segments else { throw NSFileProviderError(.noSuchItem) }
    return try resolve(segments)
  }

  /// `chats/` by the word the sidebar uses; anything else by its own name.
  private func name(of node: WorkspaceNode, _ url: URL) -> String {
    if case .chats = node { return "Chats" }
    return url.lastPathComponent
  }

  private func chats(_ project: String) throws -> [WorkspaceItem] {
    let chats = try listed(WorkspaceNode.chats(project: project).segments!)
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .map { (url: $0, title: chatTitle(project: project, chatId: $0.lastPathComponent)) }
    // Files keeps one name per folder, ignoring case, so every chat whose
    // title another shares takes its id too.
    let counts = Dictionary(chats.map { ($0.title.lowercased(), 1) }, uniquingKeysWith: +)
    return chats.map { chat in
      let id = chat.url.lastPathComponent
      let name = counts[chat.title.lowercased()]! > 1 ? "\(chat.title) (\(id))" : chat.title
      return WorkspaceItem(node: .chat(project: project, id: id), name: name, url: chat.url)
    }
  }

  // `everyProject`, in lib/domain/project.dart: the default one first, the
  // rest by name.
  private func projectDirs() -> [String] {
    list(dataDir.appendingPathComponent("projects", isDirectory: true))
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .map(\.lastPathComponent)
      .filter(WorkspaceNode.isProjectDir)
      .sorted { a, b in
        let first = WorkspaceNode.defaultProject
        return (a == first) != (b == first)
          ? a == first : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
      }
  }

  // `defaultProjectLabel`, in lib/domain/project.dart.
  private func projectLabel(_ name: String) -> String {
    name == WorkspaceNode.defaultProject ? "Default" : name
  }

  // The title lives with the conversation rather than in the workspace named
  // after it. Read behind the app's back, which is safe because documents are
  // written through a rename: there is no half-written `state.json` to catch.
  private func chatTitle(project: String, chatId: String) -> String {
    let state = dataDir.appendingPathComponent("projects/\(project)/chats/\(chatId)/state.json")
    guard let data = try? Data(contentsOf: state),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty
    else { return chatId }
    return title.replacingOccurrences(of: "/", with: "-")
  }

  /// The children of a folder [resolve] has checked. A link among them is
  /// resolved rather than trusted: the agent's own commands run in these
  /// folders, so a link out of one is something it can have been told to
  /// leave behind. Anything else is inside, its folder being.
  private func listed(_ segments: [String]) throws -> [URL] {
    let dir = try resolve(segments)
    let workspace = realPath(workspaceOf(segments))
    return list(dir).filter { child in
      (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        || inside(workspace, child)
    }
  }

  /// [segments] joined onto the data directory, still inside the workspace
  /// they name once every link in them is followed.
  private func resolve(_ segments: [String]) throws -> URL {
    let url = dataDir.appendingPathComponent(segments.joined(separator: "/"))
    guard FileManager.default.fileExists(atPath: url.path),
      inside(realPath(workspaceOf(segments)), url)
    else { throw NSFileProviderError(.noSuchItem) }
    return url
  }

  private func workspaceOf(_ segments: [String]) -> URL {
    dataDir.appendingPathComponent(
      segments.prefix(WorkspaceNode.workspaceDepth).joined(separator: "/"))
  }

  private func list(_ dir: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
      ]))
      ?? []
  }

  private func inside(_ workspace: String?, _ url: URL) -> Bool {
    guard let workspace, let path = realPath(url) else { return false }
    return path == workspace || path.hasPrefix(workspace + "/")
  }

  // `realpath(3)` rather than `resolvingSymlinksInPath`, which strips
  // `/private` off a path and so compares two spellings of one place.
  private func realPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

/// One entry in the tree.
final class WorkspaceItem: NSObject, NSFileProviderItem {
  let node: WorkspaceNode
  let filename: String
  let url: URL?
  private let values: URLResourceValues?
  /// The modification time and size, which is all a copy of it could have
  /// gone stale by.
  private let stamp: String

  init(node: WorkspaceNode, name: String, url: URL?) {
    self.node = node
    self.filename = name
    self.url = url
    let values = try? url?.resourceValues(forKeys: [
      .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
    ])
    self.values = values
    self.stamp = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
  }

  var itemIdentifier: NSFileProviderItemIdentifier { node.identifier }
  var parentItemIdentifier: NSFileProviderItemIdentifier { node.parent.identifier }

  var isFolder: Bool { url == nil || values?.isDirectory == true }

  // No renaming or moving: an identifier is the item's path, and the system
  // wants it to outlive both.
  var capabilities: NSFileProviderItemCapabilities {
    var caps: NSFileProviderItemCapabilities =
      isFolder ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
      : [.allowsReading, .allowsWriting]
    if !node.isFixed { caps.insert(.allowsDeleting) }
    return caps
  }

  // `viewerMime`, in lib/data/mime.dart: an unrecognised file is offered as
  // text, which is what most of a workspace is.
  var contentType: UTType {
    if isFolder { return .folder }
    guard let type = UTType(filenameExtension: (filename as NSString).pathExtension),
      !type.isDynamic
    else { return .plainText }
    return type
  }

  var documentSize: NSNumber? { isFolder ? nil : values?.fileSize.map(NSNumber.init) }
  var contentModificationDate: Date? { values?.contentModificationDate }

  /// The name is metadata, a chat's title changing with no change to its
  /// folder.
  var itemVersion: NSFileProviderItemVersion {
    NSFileProviderItemVersion(contentVersion: Data(stamp.utf8), metadataVersion: Data(versionKey.utf8))
  }

  /// What the working set compares to say whether this changed.
  var versionKey: String { "\(stamp):\(filename)" }
}
