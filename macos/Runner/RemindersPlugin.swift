import Cocoa
import FlutterMacOS
import UserNotifications

/// macOS's half of `ReminderAlarms`, beside the notification half both Apples
/// share (`RemindersShared.swift`): scheduling over launchd — one job per
/// request code under `~/Library/LaunchAgents/`, each a one-line `sh` that
/// checks its binary, names its store, spawns this executable detached with
/// the wake argument the Runner hides the whole app under and exits — the
/// shell is launchd's whole tracked instance, so every bootout and cancel the
/// app performs touches nothing living — and removes itself when its binary
/// is gone. The job is the wake: a fire with the process dead launches the
/// app, the clock kinds' own launch catch-up runs what is due, and a session
/// nobody came to look at quits from `doneFiring`.
extension RemindersPlugin {
  /// The banner alone, where iOS adds the sound.
  static let authorizationOptions: UNAuthorizationOptions = [.alert]
  static let presentationOptions: UNNotificationPresentationOptions = [.banner]

  /// Where every launchctl call and plist write runs, in the order asked: a
  /// call blocks on launchctl, and the main thread is the UI's.
  private static let launchd = DispatchQueue(label: "io.byterepair.entoli.launchd")

  /// The calls only this platform answers; false for one it does not know.
  func handlePlatform(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) -> Bool {
    switch call.method {
    case "schedule": schedule(call, result)
    case "cancel": cancel(call, result)
    case "staleCodes": staleCodes(call, result)
    case "doneFiring": doneFiring(result)
    default: return false
    }
    return true
  }

  /// Runs [work] on the launchd queue and answers its error, or nil, on main.
  private func onLaunchd(_ errorName: String, _ result: @escaping FlutterResult,
                         _ work: @escaping () throws -> Void) {
    Self.launchd.async {
      var answer: Any?
      do {
        try work()
      } catch {
        answer = FlutterError(code: errorName, message: String(describing: error), details: nil)
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  private func schedule(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let code = (arguments["code"] as? NSNumber)?.intValue,
          let millis = (arguments["at"] as? NSNumber)?.int64Value,
          let store = arguments["store"] as? String
    else {
      result(FlutterError(code: "arguments", message: "code, at and store required", details: nil))
      return
    }
    let calendar = arguments["calendar"] as? String
    let at = Date(timeIntervalSince1970: Double(millis) / 1000)
    onLaunchd("schedule", result) {
      try self.writeJob(code: code, at: at, store: store, calendar: calendar)
    }
  }

  /// launchd does not re-read a loaded plist, so a changed interval is
  /// bootout, rewrite, bootstrap. A bootout of a job never loaded reports
  /// failure; only the bootstrap after is a failure worth saying.
  private func writeJob(code: Int, at: Date, store: String, calendar: String?) throws {
    let label = Self.jobLabel(store: store, code: code)
    _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    let plist = Self.agentDirectory().appendingPathComponent("\(label).plist")
    try Self.agentDirectory().ensureDirectory()
    // The job runs under launchd's environment, which is not the one the old
    // app that armed it ran under — so the store rides in the command line
    // and the wake re-derives the data directory from what was written here.
    // ENTOLI_WAKE tells the app's startup it is a wake, which runs no update
    // check. The wake is spawned detached and the shell exits at once:
    // launchd's tracked instance is the shell alone, never the app, because
    // teardown of a service is SIGTERM to its tracked instance and then
    // SIGKILL (`launchd.plist(5)`, `ExitTimeOut`), and the app's own diffs
    // boot out and cancel this label all the time — a wake that exec'd
    // itself died at its first diff's bootout, before any fire ran. The app
    // is spawned directly, never through `open`: backgrounded `open -g` is
    // deferred by launch services and sometimes never reaches its engine, and
    // `-j` is worse — hidden launches never started one at all here. What
    // `open` would buy is one-instance activation, which the wake guard in
    // the Runner answers instead. The line also carries the job's own
    // removal, for the one case no writer survives — an uninstall — on which
    // launchd never tidies anything: each interval re-runs `sh` into a
    // nonzero exit forever. The binary it was written for is checked first;
    // when it is gone the shell takes the plist and the service out itself —
    // the one bootout that may exec, the shell meaning to die with the job. A
    // moved-but-alive app rewrites the job at its next launch's diff.
    guard let executable = Bundle.main.executableURL?.path else {
      throw MessageError("no executable in \(Bundle.main.bundlePath)")
    }
    let wake =
        "B='\(Self.shellQuoted(executable))'; "
        + "P='\(Self.shellQuoted(plist.path))'; "
        + "L='\(Self.shellQuoted(label))'; "
        + "if [ ! -x \"$B\" ]; then rm -f \"$P\"; "
        + "exec /bin/launchctl bootout \"gui/\(getuid())/$L\"; fi; "
        + "export ENTOLI_CONFIG='\(Self.shellQuoted(store))'; "
        + "export ENTOLI_WAKE=1; "
        + "\"$B\" entoli-wake & exit 0"
    var content: [String: Any] = [
      "Label": label,
      "ProgramArguments": [
        "/bin/sh",
        "-c",
        wake,
      ],
      // The detached app outlives the shell that spawned it; without this its
      // process group dies with the job's shell.
      "AbandonProcessGroup": true,
    ]
    if let calendar {
      // A repeating schedule's arm: wall-clock anchored, and what a sleep
      // swallows coalesces into one firing on wake (launchd.plist(5)),
      // where an interval arm is missed outright when the system is asleep
      // at the moment and measures awake time besides. The entries are the
      // next occurrence's only; the stamp re-arms after every fire.
      content["StartCalendarInterval"] = Self.calendarEntries(calendar, at: at)
    } else {
      // No calendar form exists for an arbitrary moment, so a one shot or a
      // timer arms an interval counted from the load — which is what the
      // rewrite re-dates.
      content["StartInterval"] = max(1, Int(at.timeIntervalSinceNow.rounded(.up)))
    }
    guard (content as NSDictionary).write(toFile: plist.path, atomically: true) else {
      throw MessageError("plist not written to \(plist.path)")
    }
    try bootstrap(plist.path)
  }

  /// A bootstrap right behind its own bootout often finds launchd still
  /// tearing the old service down, and exits 5 (I/O error) or 37 (operation
  /// already in progress); it is asked again a few times before that is the
  /// answer.
  private func bootstrap(_ plist: String) throws {
    var attempt = 0
    while true {
      do {
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plist])
        return
      } catch let error as MessageError
                where attempt < 4 && (error.status == 5 || error.status == 37) {
        attempt += 1
        Thread.sleep(forTimeInterval: 0.2 * Double(attempt))
      }
    }
  }

  /// What `-c` reads back as one string: a literal quote becomes the
  /// close-quote, escaped quote, open-quote idiom.
  static func shellQuoted(_ string: String) -> String {
    string.replacingOccurrences(
      of: "'", with: "'\\''", options: .literal, range: nil)
  }

  private func cancel(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let code = (arguments["code"] as? NSNumber)?.intValue,
          let store = arguments["store"] as? String
    else {
      result(FlutterError(code: "arguments", message: "code and store required", details: nil))
      return
    }
    let label = Self.jobLabel(store: store, code: code)
    onLaunchd("cancel", result) {
      // A job that was loaded gets booted; that a never-loaded one's bootout
      // reports failure is the usual answer, not news. The plist is what has
      // to be gone — a job loaded without its file is launchd's to error on,
      // and the next schedule rewrites both halves of it.
      _ = try? self.runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
      do {
        try FileManager.default.removeItem(
          at: Self.agentDirectory().appendingPathComponent("\(label).plist"))
      } catch let error as NSError where error.code == NSFileNoSuchFileError {
        // A plist that was never there is not a failure to say.
      }
    }
  }

  /// The jobs launchd still holds that nothing on the clock wants — a trigger
  /// deleted or disabled while the app was closed left its plist behind, and
  /// without the prune below it would keep waking the app on the old
  /// schedule. The listing is scoped to this store's own prefix, so a job
  /// belonging to another data directory (the debug leaf, an
  /// `ENTOLI_CONFIG` scratch) is never visible here and never pruned by
  /// a session that is not its store's. The plist's name is the code; the
  /// manager does the cancelling through the channel. Listed on the launchd
  /// queue, behind the writes and removals asked before it.
  private func staleCodes(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let store = arguments["store"] as? String
    else {
      result(FlutterError(code: "arguments", message: "store required", details: nil))
      return
    }
    let wanted = Set((arguments["wanted"] as? [Any])?
        .compactMap { ($0 as? NSNumber)?.intValue } ?? [])
    let prefix = Self.jobPrefix(store: store)
    Self.launchd.async {
      let listed = (try? FileManager.default.contentsOfDirectory(
        at: Self.agentDirectory(), includingPropertiesForKeys: nil)) ?? []
      let stale = listed.compactMap { url -> Int? in
        guard url.pathExtension == "plist" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        guard let code = Int(name.dropFirst(prefix.count)) else { return nil }
        return wanted.contains(code) ? nil : code
      }
      DispatchQueue.main.async { result(stale) }
    }
  }

  /// A wake session's work has drained; a launch nobody came to look at stops
  /// being an app and quits, the next fire's job being launchd's. The quit
  /// waits behind the launchd queue, so no rewrite is cut between its bootout
  /// and its bootstrap, and a short delay lets the reply reach Dart before
  /// the process goes. A session someone activated keeps living, from there
  /// an ordinary one.
  private func doneFiring(_ result: @escaping FlutterResult) {
    if AppDelegate.wake && !AppDelegate.userShowedUp {
      Self.launchd.async {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          NSApp.terminate(nil)
        }
      }
    }
    result(nil)
  }

  /// The label carries the bundle identifier and the data directory the jobs
  /// serve, Dart passing the latter per call so no rule of its is replicated
  /// here. Two copies of one flavour with different data directories — the
  /// debug leaf, an `ENTOLI_CONFIG` scratch — then never share a
  /// namespace, which is what keeps each one's prune to its own jobs.
  static func jobPrefix(store: String) -> String {
    "\(Bundle.main.bundleIdentifier ?? "entoli").\(storeMark(store)).trigger."
  }

  static func jobLabel(store: String, code: Int) -> String {
    "\(jobPrefix(store: store))\(code)"
  }

  /// The `StartCalendarInterval` entries of a repeating schedule's next
  /// occurrence: the hourly its minute, the rest their hour, the weekly its
  /// weekday and the monthly its day. Whatever the clamp arithmetic does to
  /// a monthly anchor's later occurrences, the entries only owe the next
  /// one — the stamp re-arms. launchd counts Weekday from Sunday 0,
  /// Calendar from Sunday 1.
  static func calendarEntries(_ repeatName: String, at: Date) -> [String: Int] {
    let parts = Calendar.current
      .dateComponents([.weekday, .day, .hour, .minute], from: at)
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    switch repeatName {
    case "daily": return ["Hour": hour, "Minute": minute]
    case "weekly":
      return ["Weekday": (parts.weekday ?? 1) - 1, "Hour": hour, "Minute": minute]
    case "monthly": return ["Day": parts.day ?? 1, "Hour": hour, "Minute": minute]
    default: return ["Minute": minute]
    }
  }

  /// launchd labels carry a restricted alphabet, and a store is an absolute
  /// path: what a separator would have been becomes a dash. Paths differing
  /// only in characters the label alphabet cannot hold, or sharing the first
  /// hundred and sixty of them, would collide — vanishing among real paths.
  static func storeMark(_ store: String) -> String {
    let mark = String(
      store.map { ch in
        ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == "_"
            ? ch
            : "-"
      }.prefix(160))
    return mark.isEmpty ? "default" : mark
  }

  /// The user's launch agents: an unsandboxed app may write there, and the
  /// user session's launchd (`gui/<uid>`) boots from it asking nothing.
  static func agentDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
  }

  /// One launchctl call, its stderr and exit status in the error it answers
  /// when it failed. Reading stderr to the end before waiting on the exit is
  /// the order that cannot deadlock a pipe.
  func runLaunchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    let output = String(
      decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MessageError(
        "launchctl \(arguments.first ?? "") exited \(process.terminationStatus): \(output)",
        status: process.terminationStatus)
    }
  }
}

extension URL {
  /// `~/Library/LaunchAgents` does not exist until something first writes one.
  func ensureDirectory() throws {
    if !FileManager.default.fileExists(atPath: path) {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
  }
}

/// The error the launchctl half answers with; its message is all the Dart log
/// ever sees of a refused boot.
struct MessageError: Error, CustomStringConvertible {
  let message: String
  /// launchctl's exit status, where launchctl is what failed.
  let status: Int32?

  init(_ message: String, status: Int32? = nil) {
    self.message = message
    self.status = status
  }

  var description: String {
    message
  }
}
