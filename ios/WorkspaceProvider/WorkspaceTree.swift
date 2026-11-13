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

/// A place in the tree. Every project is the root; a project is its
/// workspace, holding what its chats share and, by title, the folder each
/// chat works in. Those are at `chats/<id>`, which the project's listing
/// replaces: a title is what the user picks a chat by.
enum WorkspaceNode: Equatable {
  case projects
  case project(String)
  /// Segments relative to the data directory, under
  /// `projects/<name>/workspace`.
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
  private static let workspaceDepth = 3

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
        !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
        // The chats' own folder is reached through the project, not here.
        segments.count != Self.workspaceDepth + 1 || segments[3] != "chats"
      else { return nil }
      self = .path(segments)
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

  var identifier: NSFileProviderItemIdentifier {
    switch self {
    case .projects: .rootContainer
    case .project(let name): .init(Self.project + name)
    case .path(let segments): .init(segments.joined(separator: "/"))
    }
  }

  var parent: WorkspaceNode {
    switch self {
    case .projects, .project: .projects
    case .path(let segments):
      segments.count == Self.workspaceDepth + 1 || isChat
        ? .project(segments[1]) : .path(Array(segments.dropLast()))
    }
  }

  /// A place the layout makes rather than the user: the projects and a
  /// chat's own folder, which Files may add to but not delete.
  var isFixed: Bool {
    guard case .path = self else { return true }
    return isChat
  }

  /// The directory on disk, relative to the data directory; nil for the
  /// root, which is every project rather than one.
  var segments: [String]? {
    switch self {
    case .projects: nil
    case .project(let name): ["projects", name, "workspace"]
    case .path(let segments): segments
    }
  }

  /// Where a child named [name] would be, if this holds files at all.
  func child(_ name: String) -> WorkspaceNode? {
    guard let segments, !name.isEmpty, !name.contains("/") else { return nil }
    return WorkspaceNode(.init((segments + [name]).joined(separator: "/")))
  }

  /// A chat's own folder, `projects/<p>/workspace/chats/<id>`.
  private var isChat: Bool {
    guard case .path(let segments) = self else { return false }
    return segments.count == Self.workspaceDepth + 2 && segments[3] == "chats"
  }

  // The shape rule, `isProjectDirName` in lib/domain/project.dart, bar
  // `default`, which is a directory like any other here.
  private static func isProjectDir(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !unbrowsed.contains(name)
  }
}

/// Reads the tree off the disk.
struct WorkspaceTree {
  let dataDir: URL

  enum Failure: Error { case noSuchItem }

  func item(for node: WorkspaceNode) throws -> WorkspaceItem {
    switch node {
    case .projects:
      return WorkspaceItem(node: node, name: workspaceDomain.displayName, url: nil)
    case .project(let name):
      return WorkspaceItem(node: node, name: projectLabel(name), url: nil)
    case .path(let segments):
      let url = try resolve(segments)
      if node.parent != .path(Array(segments.dropLast())) {
        // A chat's folder, whose name depends on its siblings'.
        guard let chat = try children(of: node.parent).first(where: { $0.node == node })
        else { throw Failure.noSuchItem }
        return chat
      }
      return WorkspaceItem(node: node, name: url.lastPathComponent, url: url)
    }
  }

  func children(of node: WorkspaceNode) throws -> [WorkspaceItem] {
    switch node {
    case .projects:
      return projectDirs().map { WorkspaceItem(node: .project($0), name: projectLabel($0), url: nil) }
    case .project(let name):
      return projectChildren(name)
    case .path(let segments):
      return try files(in: segments)
    }
  }

  /// A folder's own files; a chat's folder in a project's is the project's
  /// to list, by title.
  private func files(in segments: [String]) throws -> [WorkspaceItem] {
    let dir = try resolve(segments)
    let workspace = try resolve(Array(segments.prefix(3)))
    return list(dir).compactMap { child in
      let node = WorkspaceNode(.init((segments + [child.lastPathComponent]).joined(separator: "/")))
      // Resolved rather than trusted: the agent's own commands run in
      // these folders, so a link out of one is something it can have been
      // told to leave behind.
      guard let node, contains(workspace, child) else { return nil }
      return WorkspaceItem(node: node, name: child.lastPathComponent, url: child)
    }
  }

  func url(of node: WorkspaceNode) throws -> URL {
    guard let segments = node.segments else { throw Failure.noSuchItem }
    return try resolve(segments)
  }

  private func projectChildren(_ project: String) -> [WorkspaceItem] {
    let id = ["projects", project, "workspace"]
    guard let workspace = try? resolve(id) else { return [] }
    var items = (try? files(in: id)) ?? []
    var taken = Set(items.map { $0.filename.lowercased() })
    let chats = workspace.appendingPathComponent("chats", isDirectory: true)
    for chat in list(chats) where isDirectory(chat) && contains(workspace, chat) {
      let chatId = chat.lastPathComponent
      // Two chats may share a title, and Files keeps one name per folder.
      var name = chatTitle(project: project, chatId: chatId)
      if taken.contains(name.lowercased()) { name += " (\(chatId.prefix(8)))" }
      taken.insert(name.lowercased())
      items.append(WorkspaceItem(node: .path(id + ["chats", chatId]), name: name, url: chat))
    }
    return items
  }

  // `everyProject`, in lib/domain/project.dart: the default one first, the
  // rest by name.
  private func projectDirs() -> [String] {
    list(dataDir.appendingPathComponent("projects", isDirectory: true))
      .filter(isDirectory)
      .map(\.lastPathComponent)
      .filter { WorkspaceNode(.init(":" + $0)) != nil }
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

  /// [segments] joined onto the data directory, still inside the workspace
  /// they name once every link in them is followed.
  private func resolve(_ segments: [String]) throws -> URL {
    let url = dataDir.appendingPathComponent(segments.joined(separator: "/"))
    let workspace = dataDir.appendingPathComponent(segments.prefix(3).joined(separator: "/"))
    guard FileManager.default.fileExists(atPath: url.path), contains(workspace, url) else {
      throw Failure.noSuchItem
    }
    return url
  }

  private func list(_ dir: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]))
      ?? []
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private func contains(_ dir: URL, _ url: URL) -> Bool {
    guard let dir = realPath(dir), let path = realPath(url) else { return false }
    return path == dir || path.hasPrefix(dir + "/")
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

  init(node: WorkspaceNode, name: String, url: URL?) {
    self.node = node
    self.filename = name
    self.url = url
    self.values = try? url?.resourceValues(forKeys: [
      .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
    ])
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

  /// The modification time and size, which is all a copy of it could have
  /// gone stale by. The name is metadata, a chat's title changing with no
  /// change to its folder.
  var itemVersion: NSFileProviderItemVersion {
    let stamp = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
    return NSFileProviderItemVersion(
      contentVersion: Data(stamp.utf8), metadataVersion: Data("\(stamp):\(filename)".utf8))
  }

  /// What the working set compares to say whether this changed.
  var versionKey: String {
    String(decoding: itemVersion.metadataVersion, as: UTF8.self)
  }
}
