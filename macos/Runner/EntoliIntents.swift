#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import AppIntents
import Foundation

// Entoli's actions in Shortcuts, on iOS and macOS alike: compiled into both
// Runners (the iOS project references this file here). The actions
// themselves are Dart's — `IntentRegistry` behind `agent_chat/intents` — and
// everything below is the Shortcuts face of them: the entities it shows, the
// intents it lists, and the bridge they all call through. See "Shortcuts" in
// macos/AGENTS.md.

// MARK: - The bridge

/// The one way in to Dart. An intent can be what launched the app, so a call
/// waits for Dart to say `ready` before it is sent: until then nothing is
/// listening to answer it.
@MainActor
final class IntentBridge {
  static let shared = IntentBridge()

  private var channel: FlutterMethodChannel?
  private var ready = false

  /// Called when an engine is up; a new engine is not ready until its Dart
  /// says so.
  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/intents", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready" else { return result(FlutterMethodNotImplemented) }
      self?.ready = true
      result(nil)
    }
    self.channel = channel
    ready = false
  }

  /// Runs the Dart action [id] and returns its result as the codec decoded
  /// it, or throws the sentence Dart refused it with.
  /// A nil argument is left out, which Dart reads as none given.
  func perform(_ id: String, _ args: [String: Any?] = [:]) async throws -> Any? {
    try await untilReady()
    guard let channel else { throw IntentFailure.notRunning }
    let values = args.compactMapValues { $0 }
    return try await withCheckedThrowingContinuation { continuation in
      channel.invokeMethod("perform", arguments: ["id": id, "args": values]) { reply in
        if let error = reply as? FlutterError {
          continuation.resume(throwing: IntentFailure(error.message ?? "Entoli could not do that."))
        } else if (reply as AnyObject) === FlutterMethodNotImplemented {
          continuation.resume(throwing: IntentFailure.notRunning)
        } else {
          continuation.resume(returning: reply)
        }
      }
    }
  }

  /// A launch takes a few seconds to reach Dart's `main`; a minute without
  /// it is an app that is not coming.
  private func untilReady() async throws {
    let deadline = Date().addingTimeInterval(60)
    while !ready {
      if Date() > deadline { throw IntentFailure.notRunning }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }
}

/// An action that did not happen, in the words Shortcuts shows.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
  let reason: String

  init(_ reason: String) { self.reason = reason }

  static let notRunning = IntentFailure("Entoli did not start in time. Open it and try again.")
  static let badReply = IntentFailure("Entoli answered with something this shortcut cannot read.")

  var localizedStringResource: LocalizedStringResource { "\(reason)" }
}

/// One of Dart's maps, read by name.
private struct Wire {
  let map: [String: Any]

  init(_ value: Any?) throws {
    guard let map = value as? [String: Any] else { throw IntentFailure.badReply }
    self.map = map
  }

  static func list(_ value: Any?) throws -> [Wire] {
    guard let list = value as? [Any] else { throw IntentFailure.badReply }
    return try list.map(Wire.init)
  }

  func string(_ name: String) throws -> String {
    guard let value = map[name] as? String else { throw IntentFailure.badReply }
    return value
  }

  func wire(_ name: String) throws -> Wire { try Wire(map[name]) }

  func bool(_ name: String) -> Bool { (map[name] as? NSNumber)?.boolValue ?? false }

  func date(_ name: String) -> Date {
    Date(timeIntervalSince1970: ((map[name] as? NSNumber)?.doubleValue ?? 0) / 1000)
  }
}

// MARK: - Entities

struct ProjectEntity: WireEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
  static let defaultQuery = ProjectQuery()

  /// The project's directory; the default project's is `default`.
  let id: String

  @Property(title: "Name")
  var label: String

  init(wire: [String: Any]) throws {
    let wire = try Wire(wire)
    id = try wire.string("id")
    label = try wire.string("label")
  }

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}

/// A query over a short list Dart hands out whole — the projects, the
/// commands — so a lookup by id is a filter of it.
protocol ListedQuery: EntityQuery where Entity: WireEntity, Entity.ID == String {
  /// The action that lists them.
  static var action: String { get }
}

/// An entity read from one of Dart's maps.
protocol WireEntity: AppEntity {
  init(wire: [String: Any]) throws
}

extension ListedQuery {
  func entities(for identifiers: [String]) async throws -> [Entity] {
    try await all().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [Entity] { try await all() }

  private func all() async throws -> [Entity] {
    try Wire.list(await IntentBridge.shared.perform(Self.action)).map { try Entity(wire: $0.map) }
  }
}

struct ProjectQuery: ListedQuery {
  typealias Entity = ProjectEntity
  static let action = "projects"
}

struct ChatEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
  static let defaultQuery = ChatQuery()

  let id: String

  @Property(title: "Title")
  var title: String

  @Property(title: "Project")
  var project: ProjectEntity

  @Property(title: "Last Updated")
  var updatedAt: Date

  @Property(title: "Pinned")
  var pinned: Bool

  fileprivate init(_ wire: Wire) throws {
    id = try wire.string("id")
    title = try wire.string("title")
    project = try ProjectEntity(wire: wire.wire("project").map)
    updatedAt = wire.date("updatedAt")
    pinned = wire.bool("pinned")
  }

  fileprivate static func many(_ reply: Any?) throws -> [ChatEntity] {
    try Wire.list(reply).map(ChatEntity.init)
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(project.label)")
  }
}

/// Finding a chat by what its title holds is the sidebar's search, so the
/// picker Shortcuts shows searches the way the app does.
struct ChatQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [ChatEntity] {
    try ChatEntity.many(
      await IntentBridge.shared.perform("chats", ["ids": identifiers]))
  }

  func entities(matching string: String) async throws -> [ChatEntity] {
    try await find(string)
  }

  func suggestedEntities() async throws -> [ChatEntity] { try await find("") }

  private func find(_ query: String) async throws -> [ChatEntity] {
    try ChatEntity.many(
      await IntentBridge.shared.perform(
        "findChats", ["query": query, "limit": 30]))
  }
}

/// One of the app's commands — what its menus and keys run — named by the
/// id it is never renamed from.
struct CommandEntity: WireEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Command"
  static let defaultQuery = CommandQuery()

  let id: String
  let label: String

  init(wire: [String: Any]) throws {
    let wire = try Wire(wire)
    id = try wire.string("id")
    label = try wire.string("label")
  }

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}

/// Asked of Dart rather than listed here, so a command the app adds is
/// offered with nothing in this file changed.
struct CommandQuery: ListedQuery {
  typealias Entity = CommandEntity
  static let action = "commands"
}

/// What asking came to: the reply, and the chat it is in. Transient — it is
/// a result, not something Shortcuts can look up again.
struct AskReply: TransientAppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reply"

  @Property(title: "Text")
  var text: String

  @Property(title: "Chat")
  var chat: ChatEntity?

  /// done, error, aborted — or running, where the shortcut did not wait.
  @Property(title: "Outcome")
  var outcome: String

  init() {
    text = ""
    chat = nil
    outcome = ""
  }

  fileprivate init(_ wire: Wire) throws {
    self.init()
    text = try wire.string("reply")
    chat = try ChatEntity(wire.wire("chat"))
    outcome = try wire.string("outcome")
  }

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(text)") }
}

// MARK: - Intents

struct NewChatIntent: AppIntent {
  static let title: LocalizedStringResource = "New Chat"
  static let description = IntentDescription(
    "Starts a chat in Entoli and returns it, without opening it.")

  @Parameter(title: "Project", description: "Where the chat goes. The default project if empty.")
  var project: ProjectEntity?

  static var parameterSummary: some ParameterSummary { Summary("New chat in \(\.$project)") }

  func perform() async throws -> some IntentResult & ReturnsValue<ChatEntity> {
    let reply = try await IntentBridge.shared.perform(
      "newChat", ["project": project?.id])
    return .result(value: try ChatEntity(Wire(reply)))
  }
}

struct OpenChatIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Chat"
  static let description = IntentDescription("Shows a chat in Entoli.")
  static let openAppWhenRun = true

  @Parameter(title: "Chat")
  var target: ChatEntity

  static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform("openChat", ["chat": target.id])
    return .result()
  }
}

struct FindChatsIntent: AppIntent {
  static let title: LocalizedStringResource = "Find Chats"
  static let description = IntentDescription(
    "Finds the chats whose title holds some text, newest first.")

  @Parameter(title: "Search", description: "Text the title holds. Every chat if empty.")
  var query: String?

  @Parameter(title: "Project", description: "Only this project's chats. Every project if empty.")
  var project: ProjectEntity?

  @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 500))
  var limit: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Find chats matching \(\.$query) in \(\.$project)") { \.$limit }
  }

  func perform() async throws -> some IntentResult & ReturnsValue<[ChatEntity]> {
    let reply = try await IntentBridge.shared.perform(
      "findChats",
      ["query": query, "project": project?.id, "limit": limit])
    return .result(value: try ChatEntity.many(reply))
  }
}

struct AskEntoliIntent: AppIntent {
  static let title: LocalizedStringResource = "Ask Entoli"
  static let description = IntentDescription(
    "Says something in a chat and returns the reply. With no chat, a new one is started.")

  @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true))
  var prompt: String

  @Parameter(title: "Chat", description: "The chat to say it in. A new chat if empty.")
  var chat: ChatEntity?

  @Parameter(title: "Project", description: "Where a new chat goes. Leave empty with a chat.")
  var project: ProjectEntity?

  @Parameter(
    title: "Wait for Reply",
    description: "Off returns at once, the turn still running.",
    default: true)
  var wait: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Ask \(\.$prompt) in \(\.$chat)") {
      \.$project
      \.$wait
    }
  }

  func perform() async throws -> some IntentResult & ReturnsValue<AskReply> {
    let reply = try await IntentBridge.shared.perform(
      "ask",
      ["prompt": prompt, "chat": chat?.id, "project": project?.id, "wait": wait])
    return .result(value: try AskReply(Wire(reply)))
  }
}

struct RunCommandIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Entoli Command"
  static let description = IntentDescription(
    "Does what one of Entoli's menu items does, on the chat it has open.")
  static let openAppWhenRun = true

  @Parameter(title: "Command")
  var command: CommandEntity

  static var parameterSummary: some ParameterSummary { Summary("Run \(\.$command)") }

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform("command.\(command.id)")
    return .result()
  }
}

/// What Siri and Spotlight offer with no shortcut made.
struct EntoliShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskEntoliIntent(),
      phrases: ["Ask \(.applicationName)"],
      shortTitle: "Ask Entoli",
      systemImageName: "bubble.left.and.text.bubble.right")
    AppShortcut(
      intent: NewChatIntent(),
      phrases: ["New chat in \(.applicationName)", "Start a \(.applicationName) chat"],
      shortTitle: "New Chat",
      systemImageName: "plus.bubble")
  }
}
