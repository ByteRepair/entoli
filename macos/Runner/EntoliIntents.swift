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

struct StartVoiceModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Voice Mode"
  static let description = IntentDescription(
    "Opens voice mode on the chat Entoli has open, or on a new one.")
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform("command.voiceMode")
    return .result()
  }
}

// MARK: - A chat's contents

struct GetReplyIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Reply"
  static let description = IntentDescription(
    "The last reply in a chat, or the whole conversation as text.")

  @Parameter(title: "Chat")
  var chat: ChatEntity

  @Parameter(title: "Whole Conversation", default: false)
  var whole: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Get the reply in \(\.$chat)") { \.$whole }
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let reply = try await IntentBridge.shared.perform(
      "reply", ["chat": chat.id, "whole": whole])
    guard let text = reply as? String else { throw IntentFailure.badReply }
    return .result(value: text)
  }
}

/// Where a chat's turn stands. The cases are Dart's `TurnStatus` names.
enum TurnStatus: String, AppEnum {
  case idle, running, waitingForApproval, waitingForAnswer

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Turn Status"
  static let caseDisplayRepresentations: [TurnStatus: DisplayRepresentation] = [
    .idle: "Idle",
    .running: "Running",
    .waitingForApproval: "Waiting for Approval",
    .waitingForAnswer: "Waiting for an Answer",
  ]
}

struct GetTurnStatusIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Turn Status"
  static let description = IntentDescription(
    "Whether a chat's turn is running, waiting on you, or done.")

  @Parameter(title: "Chat")
  var chat: ChatEntity

  static var parameterSummary: some ParameterSummary { Summary("Get the turn status of \(\.$chat)") }

  func perform() async throws -> some IntentResult & ReturnsValue<TurnStatus> {
    let reply = try await IntentBridge.shared.perform("turnStatus", ["chat": chat.id])
    guard let name = reply as? String, let status = TurnStatus(rawValue: name) else {
      throw IntentFailure.badReply
    }
    return .result(value: status)
  }
}

struct StopTurnIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop Turn"
  static let description = IntentDescription("Stops the turn running in a chat.")

  @Parameter(title: "Chat")
  var chat: ChatEntity

  static var parameterSummary: some ParameterSummary { Summary("Stop the turn in \(\.$chat)") }

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform("stopTurn", ["chat": chat.id])
    return .result()
  }
}

struct AddFilesIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Files to Workspace"
  static let description = IntentDescription(
    "Puts files in a chat's own workspace, or in the one a project's chats share.")

  @Parameter(title: "Files")
  var files: [IntentFile]

  @Parameter(title: "Chat", description: "Its own workspace. Leave empty for a project's.")
  var chat: ChatEntity?

  @Parameter(title: "Project", description: "The default project if empty.")
  var project: ProjectEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$files) to the workspace of \(\.$chat)") { \.$project }
  }

  func perform() async throws -> some IntentResult {
    let staged = try files.map(Self.stage)
    _ = try await IntentBridge.shared.perform(
      "addFiles", ["files": staged, "chat": chat?.id, "project": project?.id])
    return .result()
  }

  /// Written to a folder of its own under the temporary directory, which
  /// Dart moves into the workspace: the bytes cross no channel.
  private static func stage(_ file: IntentFile) throws -> [String: String] {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("entoli-intents", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent("file")
    try file.data.write(to: target)
    return ["name": file.filename, "staged": target.path]
  }
}

struct GetArtifactsIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Artifacts"
  static let description = IntentDescription(
    "What a chat has published, each packed as a zip of its page and files.")

  @Parameter(title: "Chat")
  var chat: ChatEntity

  static var parameterSummary: some ParameterSummary { Summary("Get the artifacts of \(\.$chat)") }

  func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
    let reply = try await IntentBridge.shared.perform("artifacts", ["chat": chat.id])
    let files = try Wire.list(reply).map { artifact in
      let url = URL(fileURLWithPath: try artifact.string("path"))
      return IntentFile(fileURL: url, filename: url.lastPathComponent, type: .zip)
    }
    return .result(value: files)
  }
}

// MARK: - Managing chats and projects

struct RenameChatIntent: AppIntent {
  static let title: LocalizedStringResource = "Rename Chat"

  @Parameter(title: "Chat")
  var chat: ChatEntity

  @Parameter(title: "Title")
  var newTitle: String

  static var parameterSummary: some ParameterSummary {
    Summary("Rename \(\.$chat) to \(\.$newTitle)")
  }

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform("renameChat", ["chat": chat.id, "title": newTitle])
    return .result()
  }
}

struct PinChatIntent: AppIntent {
  static let title: LocalizedStringResource = "Pin Chat"
  static let description = IntentDescription(
    "Pins a chat, or unpins it. A pinned chat is never temporary.")

  @Parameter(title: "Chat")
  var chat: ChatEntity

  @Parameter(title: "Pinned", default: true)
  var pinned: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Set \(\.$chat) pinned to \(\.$pinned)")
  }

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform("pinChat", ["chat": chat.id, "pinned": pinned])
    return .result()
  }
}

struct MoveChatIntent: AppIntent {
  static let title: LocalizedStringResource = "Move Chat to Project"

  @Parameter(title: "Chat")
  var chat: ChatEntity

  @Parameter(title: "Project")
  var project: ProjectEntity

  static var parameterSummary: some ParameterSummary { Summary("Move \(\.$chat) to \(\.$project)") }

  func perform() async throws -> some IntentResult {
    _ = try await IntentBridge.shared.perform(
      "moveChat", ["chat": chat.id, "project": project.id])
    return .result()
  }
}

struct DeleteChatIntent: AppIntent {
  static let title: LocalizedStringResource = "Delete Chat"
  static let description = IntentDescription(
    "Deletes a chat, its conversation and its own workspace. Asks first.")

  @Parameter(title: "Chat")
  var chat: ChatEntity

  static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$chat)") }

  func perform() async throws -> some IntentResult {
    let dialog: IntentDialog = "Delete “\(chat.title)”? This cannot be undone."
    if #available(iOS 18, macOS 15, *) {
      try await requestConfirmation(actionName: .go, dialog: dialog)
    } else {
      try await requestConfirmation(result: .result(dialog: dialog))
    }
    _ = try await IntentBridge.shared.perform("deleteChat", ["chat": chat.id])
    return .result()
  }
}

struct CreateProjectIntent: AppIntent {
  static let title: LocalizedStringResource = "Create Project"

  @Parameter(title: "Name")
  var name: String

  static var parameterSummary: some ParameterSummary { Summary("Create a project called \(\.$name)") }

  func perform() async throws -> some IntentResult & ReturnsValue<ProjectEntity> {
    let reply = try await IntentBridge.shared.perform("createProject", ["name": name])
    guard let wire = reply as? [String: Any] else { throw IntentFailure.badReply }
    return .result(value: try ProjectEntity(wire: wire))
  }
}

struct GetProjectsIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Projects"
  static let description = IntentDescription("Every project, the default one first.")

  func perform() async throws -> some IntentResult & ReturnsValue<[ProjectEntity]> {
    .result(value: try await ProjectQuery().suggestedEntities())
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
    AppShortcut(
      intent: StartVoiceModeIntent(),
      phrases: ["Talk to \(.applicationName)", "Start \(.applicationName) voice mode"],
      shortTitle: "Voice Mode",
      systemImageName: "waveform")
  }
}
