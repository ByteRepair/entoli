import "dart:async";
import "dart:convert";
import "dart:ffi" show Abi;
import "dart:io";

import "package:collection/collection.dart";
import "package:flutter/foundation.dart" show mustCallSuper, protected;
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../../../core/log.dart";
import "../../../../core/tls.dart";
import "../../../../domain/download.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_capability.dart";
import "../../../../domain/model_registry.dart";
import "../../../../domain/shell.dart" show guestHome, guestPath, shellQuoted;
import "../../../download.dart";
import "../../../local/file_modes.dart";
import "../hosted_models.dart";
import "../llm_client.dart";
import "cli_release.dart";
import "provider.dart";

export "cli_release.dart";

/// Another harness's command-line program — Claude CLI, Codex — answering in
/// the model's place. What is configured is the program and the environment
/// it runs with; there is no URL and no key, the program holding its own
/// sign-in.
///
/// This class is the interface, and what every such program shares: finding
/// the executable, its environment, and a [CliClient] that pools sessions so
/// one harness process carries a conversation across the steps of a turn.
/// What a session *is* — a process per call, a long-lived one fed over stdin,
/// a server it talks to — is the subclass's, through [start].
/// Where a CLI's program runs, and so everything about starting it that
/// differs by platform: which build of it to fetch, what it starts with,
/// how its packages go in, and how a process is made. This machine on a
/// desktop ([HostCliGuest]), Android's Linux under proot, iOS's in the
/// emulator ([LinuxCliGuest]). A [CliProvider] reaches its program through
/// this and nothing else.
abstract class CliGuest {
  const CliGuest();

  /// The machine a release is chosen for.
  Abi get abi;

  /// Whether its programs link against musl, as Alpine's do: which build a
  /// publisher that makes both is asked for.
  bool get musl;

  /// What a program starts with, below its provider's own variables. [host]
  /// is the provider's take on this machine's environment, what a program
  /// run here inherits; [linux] what it is told in a Linux of its own.
  Map<String, String> environment({
    required Map<String, String> host,
    required Map<String, String> linux,
  });

  /// The command that installs [packages] where the program runs, or null
  /// where there is nothing to install them into.
  List<String>? install(List<String> packages);

  /// [argv] started from [cwd] with [environment], each of [shared] reachable
  /// at its own host path, so a path the app hands the program is one answer
  /// inside and out. Throws an [LlmException] where it cannot run yet.
  ///
  /// [terminal] runs it on a terminal, for a program whose prompts read keys
  /// only from one — Claude CLI's sign-in code — where the guest has one to
  /// give ([hasTerminal]); over pipes otherwise.
  Future<CliProcess> start(
    List<String> argv, {
    required String cwd,
    required Map<String, String> environment,
    required List<String> shared,
    bool terminal = false,
  }) async {
    final onOne = terminal && hasTerminal;
    final process = await spawn(
      argv,
      cwd: cwd,
      environment: environment,
      shared: shared,
      terminal: onOne,
    );
    return onOne ? TerminalCliProcess(process) : process;
  }

  /// Whether a program here can be given a terminal.
  @protected
  bool get hasTerminal;

  /// [argv] started as it is: on a terminal [terminalColumns] by
  /// [terminalRows] where [terminal], over pipes otherwise. [start] less
  /// reading it as a terminal.
  @protected
  Future<CliProcess> spawn(
    List<String> argv, {
    required String cwd,
    required Map<String, String> environment,
    required List<String> shared,
    required bool terminal,
  });

  /// The size a terminal is given: wide, so a program does not wrap a long
  /// link across lines for a screen nobody looks at.
  static const terminalColumns = 4096;
  static const terminalRows = 40;

  /// [terminalColumns] by [terminalRows] set from inside, for a terminal
  /// that `script` makes at its own size.
  static const _terminalSize =
      "stty cols $terminalColumns rows $terminalRows 2>/dev/null";

  /// util-linux's `script` running [argv] on a terminal: one command line,
  /// since its -c takes a string, with the output flushed as it comes and
  /// the program's exit code its own.
  @protected
  static List<String> utilLinuxScript(List<String> argv) => [
    "script",
    "-qfec",
    "$_terminalSize; exec ${argv.map(shellQuoted).join(" ")}",
    "/dev/null",
  ];
}

/// This machine: a desktop's, whose programs are its own processes.
class HostCliGuest extends CliGuest {
  /// [loginPath] is the login shell's `PATH`, which a desktop launch's
  /// inherited one misses what the user's profile adds to; null leaves the
  /// inherited one. [abi] and [launch] are this machine's unless a test
  /// names others.
  const HostCliGuest({this.loginPath, Abi? abi, this.launch = launchProcess})
    : _abi = abi; // ignore: prefer_initializing_formals

  final String? loginPath;
  final Abi? _abi;
  final LaunchCli launch;

  @override
  Abi get abi => _abi ?? Abi.current();

  /// What Anthropic's installer looks for to tell musl from glibc.
  @override
  bool get musl =>
      Platform.isLinux &&
      (File("/lib/libc.musl-x86_64.so.1").existsSync() ||
          File("/lib/libc.musl-aarch64.so.1").existsSync());

  @override
  Map<String, String> environment({
    required Map<String, String> host,
    required Map<String, String> linux,
  }) => {...host, "PATH": ?loginPath};

  @override
  List<String>? install(List<String> packages) => null;

  /// The system's own `script`: BSD's on macOS, which takes the program as
  /// words, and util-linux's on a Linux that has it. Windows has none, and
  /// a desktop's sign-in opens a browser rather than asking for a code.
  @override
  bool get hasTerminal =>
      Platform.isMacOS ||
      (Platform.isLinux && File("/usr/bin/script").existsSync());

  @override
  Future<CliProcess> spawn(
    List<String> argv, {
    required String cwd,
    required Map<String, String> environment,
    required List<String> shared,
    required bool terminal,
  }) {
    final command = !terminal
        ? argv
        : Platform.isMacOS
        ? [
            "/usr/bin/script",
            "-q",
            "/dev/null",
            "/bin/sh",
            "-c",
            '${CliGuest._terminalSize}; exec "\$@"',
            "sh",
            ...argv,
          ]
        : CliGuest.utilLinuxScript(argv);
    return launch(
      command.first,
      command.sublist(1),
      workingDirectory: cwd,
      environment: environment,
    );
  }
}

/// A Linux of the app's own, apart from the machine it is on: Android's
/// Alpine under proot and iOS's in the emulator. None of the app's own
/// environment reaches it, being Android's or iOS's and meaning nothing to
/// a Linux program; Alpine's basics stand in its place.
abstract class LinuxCliGuest extends CliGuest {
  const LinuxCliGuest();

  static const basics = {
    "HOME": guestHome,
    "PATH": guestPath,
    "LANG": "C.UTF-8",
  };

  @override
  bool get musl => true;

  @override
  Map<String, String> environment({
    required Map<String, String> host,
    required Map<String, String> linux,
  }) => {...basics, ...linux};

  @override
  List<String>? install(List<String> packages) => [
    "apk",
    "add",
    "--no-cache",
    ...packages,
  ];

  @override
  bool get hasTerminal => true;

  /// [argv] with its browser: a Linux of the app's own has none to open a
  /// page in, so `BROWSER` names one ([_opener]) that hands the page to the
  /// app instead, as a line on the program's terminal saying [cliOpenMarker]
  /// and its address. The page a sign-in asks to open is the one whose
  /// callback finishes it on its own. Written into the guest the first time
  /// it is asked for, so a Linux set up before this needs nothing done to
  /// it.
  @protected
  static List<String> withBrowser(List<String> argv) => [
    "/bin/sh",
    "-c",
    _withBrowser,
    "sh",
    ...argv,
  ];

  /// [argv] on a terminal by util-linux's `script`, which Alpine keeps in
  /// util-linux-misc and its busybox lacks: installed the first time a
  /// terminal is asked for, for a guest that has no terminal of its own to
  /// give.
  @protected
  static List<String> underScript(List<String> argv) => [
    "/bin/sh",
    "-c",
    "command -v script >/dev/null 2>&1 || "
        "apk add --no-cache util-linux-misc >/dev/null 2>&1; "
        'exec "\$@"',
    "sh",
    ...CliGuest.utilLinuxScript(argv),
  ];

  /// Where the browser that hands a page to the app is kept in the guest.
  static const _opener = "/usr/local/bin/entoli-open";

  /// What [withBrowser] runs before the program: the browser written where
  /// it is missing — a script that prints the marker and its first argument
  /// to the terminal — then the program with `BROWSER` naming it.
  static const _withBrowser =
      "[ -x $_opener ] || { mkdir -p /usr/local/bin && "
      "printf '#!/bin/sh\\nprintf \"$cliOpenMarker %%s\\\\n\" \"\$1\" > /dev/tty\\n' "
      "> $_opener && chmod +x $_opener; }; "
      'exec env BROWSER=$_opener "\$@"';
}

/// What a program's browser in a Linux of the app's own says before the
/// address of a page it was asked to open; see [LinuxCliGuest.withBrowser].
const cliOpenMarker = "entoli-open";

/// A program on a terminal, read and written as one over pipes: Enter is a
/// carriage return, which a program reading keys takes as Enter where a
/// line feed is not, and what it prints comes without the terminal's
/// escapes — colours, cursor moves, a link's hyperlink wrapping — or the
/// carriage return ending each line, so a link in it is found as it is.
/// Its error output is the terminal's own, on its output.
class TerminalCliProcess extends CliProcess {
  TerminalCliProcess(this._process);

  final CliProcess _process;

  static final _escapes = RegExp(
    // OSC (a hyperlink, a title) to BEL or ST; CSI; any other two-byte
    // escape; a carriage return.
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]|\r",
  );

  @override
  Stream<String> get lines =>
      _process.lines.map((line) => line.replaceAll(_escapes, ""));

  @override
  Stream<String> get errors => _process.errors;

  @override
  void write(String text) => _process.write(text);

  @override
  void writeLine(String line) => write("$line\r");

  @override
  Future<void> closeInput() => _process.closeInput();

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill({bool force = false}) => _process.kill(force: force);
}

abstract class CliProvider extends LlmProvider with KeyFree {
  /// [guest] is where its program runs, [platformGuest] unless a test names
  /// one.
  const CliProvider(super.config, {CliGuest? guest})
    : _guest = guest; // ignore: prefer_initializing_formals

  final CliGuest? _guest;

  /// Where this platform runs the programs, set once by `main`; this
  /// machine until then. Null where the build has nowhere to run one: an
  /// Android whose APK carries no proot.
  static CliGuest? platformGuest = const HostCliGuest();

  /// Where this provider's program runs.
  CliGuest? get guest => _guest ?? platformGuest;

  CliGuest get _runsIn =>
      guest ??
      (throw LlmException(
        "This build has nowhere to run ${config.displayName}.",
      ));

  /// Where the programs' sessions keep what they run with, set once by
  /// `main` to the app's cache. Null — a test, a build that never set it —
  /// is one fixed folder under the system's temp.
  static String? cacheRoot;

  /// What [command] is when the config names none: a bare name, looked up on
  /// `PATH`.
  String get defaultCommand;

  /// What it is, in the words the provider list and dialog show.
  String get about =>
      "Runs ${config.displayName} on this computer, signed in as it already "
      "is. Its own tools are off; it uses Entoli's.";

  /// Whose plan answers through it, by the name its user pays for: "Claude",
  /// "ChatGPT".
  String get planName;

  /// Whose account its prompts go to, for the provider list's tag.
  String get account => "Uses your $planName account";

  /// The folder of [cacheRoot] that is this program's: `bin/` the program
  /// itself, shared by every provider on it, and per provider `data/<id>/`
  /// and `work/<id>/`.
  String get workFolder;

  Directory get workRoot => Directory(
    p.join(
      cacheRoot ?? p.join(Directory.systemTemp.path, "entoli"),
      workFolder,
    ),
  );

  /// The provider's own name for its folders, which a provider not yet
  /// saved does not have.
  String get _folderId => config.id.isEmpty ? "unsaved" : config.id;

  /// What the program keeps — its account above all, and its settings,
  /// history and caches — in place of its own home under the user's: one per
  /// provider, so two on the same program can be two accounts, and Entoli's
  /// are apart from the user's own `claude` or `codex`. Told to the program
  /// by [homeEnvironment].
  String get dataDirectory => p.join(workRoot.path, "data", _folderId);

  /// The variables that point the program at [home] for everything it keeps.
  Map<String, String> homeEnvironment(String home);

  /// The empty folder every session of this provider runs in, so nothing a
  /// project keeps for the program is picked up from it. Kept apart from
  /// [dataDirectory], so what the program keeps and what it works in never
  /// mix.
  String get workPath => p.join(workRoot.path, "work", _folderId);

  /// [workPath], made with [dataDirectory] before anything runs.
  Future<String> workDirectory() async {
    await Directory(dataDirectory).create(recursive: true);
    return (await Directory(workPath).create(recursive: true)).path;
  }

  /// Takes this provider's [dataDirectory] and work folder away — its
  /// sign-in with them — for a provider that is removed.
  Future<void> forget() async {
    for (final path in [dataDirectory, workPath]) {
      final dir = Directory(path);
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  }

  /// This program for [config], the same ports kept: the way a provider
  /// read from one entry is had for another — its folders are by id.
  CliProvider withConfig(LlmProviderConfig config);

  /// The models the program takes by name, offered beside the user's own.
  List<ModelInfo> get knownModels;

  /// Whether there is anywhere to run the program: false only where the
  /// build has no [guest] at all.
  @override
  bool get supported => guest != null;

  /// What the program needs installed beside it where its [guest] installs
  /// packages, by the guest's package names: nothing, unless a subclass
  /// knows better.
  List<String> get guestPackages => const [];

  /// What the program is told in a Linux guest beyond the guest's basics.
  Map<String, String> get guestEnvironment => const {};

  /// The machine its program runs on, which a release is chosen for.
  Abi get abi => _runsIn.abi;

  /// Whether the program runs against musl, for a publisher that builds
  /// for both.
  bool get musl => _runsIn.musl;

  /// The newest release of the program for [abi], asked of its publisher
  /// over [client]. Null where it publishes none for that machine.
  Future<CliRelease?> latestRelease(http.Client client);

  /// What the program is asked to say whether it is signed in: it exits 0
  /// when it is.
  List<String> get statusArguments;

  /// What signs the program in: it prints the page to sign in on, waits for
  /// the sign-in there, stores what it was given, and exits 0.
  List<String> get signInArguments;

  /// What signs the program out of the account in [dataDirectory].
  List<String> get signOutArguments;

  /// Entoli's own copy of the program, kept in [workRoot] beside the folder
  /// its sessions run in, which is what the cache is for: deleted, it is
  /// downloaded again rather than lost.
  String get ownCopy => p.join(_bin, fileOf(defaultCommand));

  String get _bin => p.join(workRoot.path, "bin");

  /// [name] as a program's file on [on]. One rule for where a release is
  /// put and where it is looked for.
  static String programFile(String name, Abi on) =>
      const {Abi.windowsArm64, Abi.windowsIA32, Abi.windowsX64}.contains(on)
      ? "$name.exe"
      : name;

  /// [name] as a program's file where this provider's program runs.
  String fileOf(String name) => programFile(name, _runsIn.abi);

  /// Programs the CLI runs from beside itself, which a copy is not whole
  /// without. None unless a subclass knows of one.
  List<String> get companions => const [];

  /// [ownCopy] there, with every one of its [companions].
  bool get installed => [
    ownCopy,
    for (final name in companions) p.join(_bin, fileOf(name)),
  ].every((path) => File(path).existsSync());

  /// [latestRelease] fetched, each of its files checked against the hash its
  /// publisher states, taken out of whatever it is packed in, and put in
  /// [ownCopy]'s folder — each in one rename, the CLI's own last, so a copy
  /// in use is replaced whole and one only half fetched is not [installed].
  /// Over [client] where given, which the run closes.
  Stream<DownloadProgress> install({http.Client? client}) {
    final web = client ?? tlsClient();
    Future<void> discard() async {
      final bin = Directory(_bin);
      if (!bin.existsSync()) return;
      await for (final entry in bin.list()) {
        if (entry.path.endsWith(".part") || entry.path.endsWith(".new")) {
          await entry.delete();
        }
      }
    }

    return DownloadRun(
      client: web,
      discard: discard,
      run: (run) async {
        final release =
            await latestRelease(web) ??
            (throw UnsupportedError(
              "${config.displayName} publishes no build for this computer",
            ));
        await Directory(_bin).create(recursive: true);
        // Alongside the download rather than after it: the libraries do not
        // wait on the program. Awaited before anything is put in place; its
        // failure is the install's, and a download that fails first leaves
        // it ignored.
        final packages = _installGuestPackages()..ignore();
        final total = release.bytes;
        var done = 0;
        for (final file in release.files) {
          final part = p.join(_bin, "${file.name}.part");
          final digest = await run.fetchSha256(
            url: "${file.url}",
            to: part,
            total: total,
            done: done,
          );
          if (run.cancelled) return;
          if (digest != file.sha256.toLowerCase()) {
            throw FormatException(
              "${file.url} does not match the checksum its publisher states",
            );
          }
          done += File(part).lengthSync();
          run.report(
            DownloadProgress(
              received: done,
              total: total ?? 0,
              unpacking: true,
            ),
          );
          final staged = p.join(_bin, "${file.name}.new");
          await file.packing.place(File(part), staged);
          makeExecutable(staged);
        }
        await packages;
        for (final file in release.files) {
          await File(
            p.join(_bin, "${file.name}.new"),
          ).rename(p.join(_bin, file.name));
        }
      },
    ).stream;
  }

  /// [guestPackages] into the [guest], before the program is in place, so a
  /// copy that is [installed] has what it runs with. Nothing where the guest
  /// installs nothing or there is nothing to install.
  Future<void> _installGuestPackages() async {
    if (guestPackages.isEmpty) return;
    final install = _runsIn.install(guestPackages);
    if (install == null) return;
    final (:code, :said) = await _exitOf(
      await _start(
        install,
        cwd: workRoot.path,
        environment: _runsIn.environment(host: const {}, linux: const {}),
      ),
    );
    if (code != 0) {
      throw LlmException(
        "Installing ${guestPackages.join(", ")} in the Linux failed "
        "($code): $said",
      );
    }
  }

  /// Takes [ownCopy] and its [companions] away, and the program falls back
  /// to whatever else [locate] finds.
  Future<void> uninstall() async {
    final bin = Directory(_bin);
    if (bin.existsSync()) await bin.delete(recursive: true);
  }

  /// Whether the program is signed in, by its own [statusArguments].
  Future<bool> signedIn() async =>
      (await _exitOf(await run(statusArguments))).code == 0;

  /// Signs the program out, by its own [signOutArguments]; whether it was
  /// signed in or not, it is not after.
  Future<void> signOut() async {
    final (:code, said: _) = await _exitOf(await run(signOutArguments));
    if (code != 0) {
      logFailure("cli", "signing ${config.displayName} out exited $code");
    }
  }

  /// [process] to its end, both its outputs read so it never blocks on a
  /// full pipe, and the tail of what it said on its error output kept.
  static Future<({int code, StderrTail said})> _exitOf(
    CliProcess process,
  ) async {
    final said = StderrTail();
    unawaited(process.lines.drain<void>());
    process.errors.listen(said.add);
    return (code: await process.exitCode, said: said);
  }

  /// The program the config names, or null where it leaves it to the default.
  String? get _named {
    final named = config.command?.trim();
    return named == null || named.isEmpty ? null : named;
  }

  String get command => _named ?? defaultCommand;

  /// What of the app's own environment [name] is passed on as. All of it,
  /// unless a subclass knows of variables that belong to something else.
  bool inherits(String name, Map<String, String> inherited) => true;

  /// What its [guest] starts a program with — this machine's environment
  /// less what [inherits] keeps out, or a Linux guest's basics and
  /// [guestEnvironment] — and the config's variables over it.
  Map<String, String> get environment => {
    ..._runsIn.environment(
      host: inheritedFrom(Platform.environment),
      linux: guestEnvironment,
    ),
    ...homeEnvironment(dataDirectory),
    ...config.env,
  };

  /// The program, started on [arguments] in its work folder, with
  /// [environment] below its own.
  Future<CliProcess> run(
    List<String> arguments, {
    Map<String, String> environment = const {},
    bool terminal = false,
  }) async => _start(
    [executable(), ...arguments],
    cwd: await workDirectory(),
    terminal: terminal,
    environment: {...environment, ...this.environment},
  );

  /// [argv] started from [cwd] with [environment] by its [guest], the
  /// program's cache folder reachable at its own path there; on a terminal
  /// where [terminal].
  Future<CliProcess> _start(
    List<String> argv, {
    required String cwd,
    required Map<String, String> environment,
    bool terminal = false,
  }) => _runsIn.start(
    argv,
    cwd: cwd,
    environment: environment,
    shared: [workRoot.path],
    terminal: terminal,
  );

  /// [inherited] less what [inherits] keeps out.
  Map<String, String> inheritedFrom(Map<String, String> inherited) => {
    for (final MapEntry(:key, :value) in inherited.entries)
      if (inherits(key, inherited)) key: value,
  };

  /// Where the program may be when [command] was left to its default and
  /// `PATH` has none: a copy another app ships, which may move with that
  /// app's updates. None unless a subclass knows of one.
  List<String> get bundledCopies => const [];

  /// The app [bundledCopies] come with, for saying where it was looked for.
  String get bundler => "";

  /// [command] as a path to run, or null where there is none. A command the
  /// config names is taken as it is, or looked for on [environment]'s `PATH`
  /// where it is a bare name. Left to the default, it is Entoli's own copy
  /// first — the one the welcome tour installs and signs in — then the
  /// default name on `PATH`, then the first of [bundledCopies].
  String? locate() => _named != null
      ? _onPath()
      : (installed ? ownCopy : null) ??
            _onPath() ??
            bundledCopies.where((path) => File(path).existsSync()).firstOrNull;

  String? _onPath() {
    final name = command;
    final windows = Platform.isWindows;
    bool runnable(String path) => File(path).existsSync();
    if (p.isAbsolute(name) || name.contains(p.separator)) {
      return runnable(name) ? name : null;
    }
    final env = environment;
    final extensions = windows
        ? ["", ...(env["PATHEXT"] ?? ".EXE;.CMD;.BAT").toLowerCase().split(";")]
        : const [""];
    for (final dir in (env["PATH"] ?? "").split(windows ? ";" : ":")) {
      if (dir.isEmpty) continue;
      for (final ext in extensions) {
        final candidate = p.join(dir, "$name$ext");
        if (runnable(candidate)) return candidate;
      }
    }
    return null;
  }

  /// [locate], or an [LlmException] saying what was not found and where it
  /// was looked for.
  String executable() =>
      locate() ??
      (throw LlmException(
        p.isAbsolute(command)
            ? "$command does not exist"
            : "$command was not found on PATH${bundledCopies.isEmpty ? "" : " or in $bundler"}. "
                  "Install it, or set its path in the provider's settings.",
      ));

  /// A session of the program for [spec], started and ready for its first
  /// [CliSession.exchange].
  Future<CliSession> start(CliSessionSpec spec);

  @override
  LlmClient client(String? apiKey) => CliClient(this);

  @override
  List<ModelInfo> models(ModelCatalog catalog) {
    if (!supported) return const [];
    final own = {for (final m in config.customModels) m.id: m};
    return [...own.values, ...knownModels.where((m) => !own.containsKey(m.id))];
  }

  /// The program's models are in no catalog, so the window a chat on one
  /// reports is [knownModels]'s.
  @override
  ModelInfo? modelInfo(String? modelId) =>
      super.modelInfo(modelId) ??
      knownModels.where((m) => m.id == modelId).firstOrNull;

  @override
  List<Model> serve(String id, ModelInfo? info, ModelHost host) => supported
      ? super.serve(
          id,
          info ?? knownModels.where((m) => m.id == id).firstOrNull,
          host,
        )
      : const [];
}

/// What a session is started for: everything the program is told once, on
/// its command line, rather than per message. A call that differs in any of
/// it needs a session of its own.
class CliSessionSpec {
  CliSessionSpec({
    required this.model,
    required this.system,
    required this.tools,
    this.reasoningEffort,
    this.responseCap,
  });

  final String model;

  /// The leading system messages, joined.
  final String system;
  final List<LlmTool> tools;
  final String? reasoningEffort;

  /// The user's cap on a reply, where they set one: a program that takes it
  /// is told when it starts, so a session is only reused under the same.
  /// Unset, each program writes to its model's own limit.
  final int? responseCap;

  /// The tools as one string, compared by value: each step builds its
  /// definitions afresh, so two equal schemas are seldom the same map.
  late final toolsKey = jsonEncode([
    for (final t in tools) [t.name, t.description, t.schema],
  ]);

  bool sameAs(CliSessionSpec other) =>
      model == other.model &&
      system == other.system &&
      reasoningEffort == other.reasoningEffort &&
      responseCap == other.responseCap &&
      toolsKey == other.toolsKey;
}

/// One running instance of the program, carrying one conversation.
///
/// It owns whatever the program needs for its life — the process, a server
/// it reaches the tools through, temporary files — and [close] takes all of
/// it down.
abstract class CliSession {
  CliSession(this.spec);

  final CliSessionSpec spec;

  /// False once the program has gone, or the conversation it holds can no
  /// longer be followed: such a session takes no more exchanges.
  bool get alive;

  /// Whether [rest] — the conversation past what this session has already
  /// seen — can be fed to it as it stands. A fresh session takes anything;
  /// one waiting on tool results takes exactly those.
  bool accepts(List<LlmMessage> rest);

  /// One model call: [rest] fed in, the reply streamed out, closed by exactly
  /// one [LlmCompletion]. The session's state is up to date by the time that
  /// completion is delivered. Failures are [LlmException]s on the stream.
  Stream<LlmChunk> exchange(List<LlmMessage> rest);

  /// Ends the program, gracefully where it will go, by force where it will
  /// not, and frees what it held. Safe to call twice.
  Future<void> close();
}

/// A [CliSession] over one process that speaks JSON a line at a time, which
/// is what every program's session shares: the exchange in progress, the
/// output read, how a session ends and how it says it died. What a line
/// means and how input is written is the subclass's, through [line],
/// [begin] and [answer].
abstract class CliProcessSession extends CliSession {
  CliProcessSession(super.spec, this.name);

  /// The program, as a failure names it: "Codex CLI".
  final String name;

  CliProcess? _process;
  var _alive = true;
  var _fresh = true;
  StreamController<LlmChunk>? _current;
  final _stderr = StderrTail();

  /// Set once [close] has begun: nothing more is written, and an exit is
  /// expected rather than a failure.
  @protected
  var closing = false;

  @override
  bool get alive => _alive;

  /// The exchange in progress, null between them.
  @protected
  StreamController<LlmChunk>? get current => _current;

  /// The ids of the calls the last reply made that still wait on results.
  @protected
  List<String> get held;

  /// Whether [rest], with nothing held, is input the program takes now.
  @protected
  bool takes(List<LlmMessage> rest) => rest.every(fromUser);

  @override
  bool accepts(List<LlmMessage> rest) {
    if (!alive || _current != null || rest.isEmpty) return false;
    if (_fresh) return true;
    final ids = held;
    return ids.isNotEmpty ? answersAll(rest, ids) : takes(rest);
  }

  @override
  Stream<LlmChunk> exchange(List<LlmMessage> rest) {
    final out = StreamController<LlmChunk>();
    if (!accepts(rest)) {
      out
        ..addError(const LlmException("The CLI session cannot take this"))
        ..close();
      return out.stream;
    }
    _current = out;
    _fresh = false;
    // Results answer the calls the program holds, which is what lets it
    // carry on to its next reply; anything else is new input.
    held.isNotEmpty ? answer(rest) : begin(rest);
    return out.stream;
  }

  /// Feeds [rest], input from the user's side, to the program.
  @protected
  void begin(List<LlmMessage> rest);

  /// Answers the held calls with [results], one for each.
  @protected
  void answer(List<LlmMessage> results);

  /// Starts the program, by [CliProvider.run], and reads it: each line of
  /// its output that is a JSON object goes to [line].
  @protected
  Future<void> run(
    CliProvider provider,
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) async {
    final process = await provider.run(arguments, environment: environment);
    _process = process;
    process.lines.listen(_read, onError: (Object e) => fail("$e"));
    process.errors.listen(_stderr.add);
    unawaited(process.exitCode.then(_exited));
  }

  void _read(String text) {
    if (text.trim().isEmpty) return;
    final Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (message is Map<String, dynamic>) line(message);
  }

  /// One message of the program's output.
  @protected
  void line(Map<String, dynamic> message);

  /// Writes [message] to the program, unless it is closing.
  @protected
  void write(Map<String, dynamic> message) {
    if (closing) return;
    _process?.writeLine(jsonEncode(message));
  }

  /// Output that came with no exchange to take it: the program went on
  /// without Entoli's loop, and what it holds is no longer the conversation
  /// the loop has.
  @protected
  void strayed() => _alive = false;

  /// Ends the exchange in progress, if any, with [last] or [error]. It is
  /// detached first, so nothing that follows reaches it.
  @protected
  @mustCallSuper
  void end({LlmChunk? last, Object? error}) {
    final out = _current;
    _current = null;
    if (out == null) return;
    if (error != null) out.addError(error);
    if (last != null) out.add(last);
    unawaited(out.close());
  }

  @protected
  void fail(String reason) {
    _alive = false;
    end(error: LlmException(reason));
  }

  void _exited(int code) {
    _alive = false;
    final said = _stderr.toString();
    final reason = said.isEmpty
        ? "$name exited ($code)"
        : "$name exited ($code): $said";
    gone(reason);
    if (closing) return;
    logFailure("llm", "$name exited with $code");
    fail(reason);
  }

  /// The program has gone, for [reason]: whatever waits on it is failed.
  @protected
  void gone(String reason) {}

  @override
  Future<void> close() async {
    if (closing) return;
    closing = true;
    _alive = false;
    end();
    final process = _process;
    if (process != null) await stopProcess(process, name);
    await release();
  }

  /// Frees what the subclass holds beyond the process, once it has stopped.
  @protected
  Future<void> release() async {}
}

/// [session], made ready by [open]. A failure on the way closes it and is an
/// [LlmException] saying the program would not start.
Future<S> opened<S extends CliProcessSession>(
  CliProvider provider,
  S session,
  Future<void> Function() open,
) async {
  try {
    await open();
  } catch (e) {
    await session.close();
    if (e is LlmException) rethrow;
    throw LlmException("Could not start ${provider.command}: $e");
  }
  return session;
}

/// An [LlmClient] over a [CliProvider]'s sessions. The agent loop resends the
/// whole conversation every step; this finds the session that has seen all
/// but the newest of it and feeds it only that, so a turn's steps run in one
/// process with the program's own context and cache, and starts a fresh one
/// where none has.
///
/// One client serves the parent agent, its sub-agents and the title call at
/// once, so it holds several sessions, each busy with one call or parked.
class CliClient implements LlmClient {
  CliClient(this.provider);

  final CliProvider provider;

  /// How long a parked session is kept for its conversation's next step.
  static const idleFor = Duration(minutes: 10);

  /// How many parked sessions are kept at most; the oldest goes first.
  static const maxIdle = 4;

  final _idle = <_Parked>[];
  final _live = <CliSession>{};
  var _closed = false;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
    LlmOutputLimit outputLimit = const LlmOutputLimit(),
  }) async* {
    if (_closed) throw const LlmException("The client was closed");
    final leading = messages.takeWhile((m) => m.role == LlmRole.system);
    final conversation = messages.skip(leading.length).toList();
    final spec = CliSessionSpec(
      model: model,
      system: joinedSystemText(leading.toList()),
      tools: tools,
      reasoningEffort: reasoningEffort,
      responseCap: outputLimit.cap,
    );
    var (session, seen) = _take(spec, conversation);
    if (session == null) {
      session = await provider.start(spec);
      seen = 0;
      if (_closed) {
        await session.close();
        throw const LlmException("The client was closed");
      }
    }
    _live.add(session);
    var parked = false;
    try {
      await for (final chunk in session.exchange(conversation.sublist(seen))) {
        if (chunk is LlmCompletion && session.alive) {
          // Parked before it is handed on: a consumer that stops listening
          // once it has the reply must not take the session down with it.
          _park(session, [...conversation.map(markOf), markOf(chunk.message)]);
          parked = true;
        }
        yield chunk;
      }
    } finally {
      if (!parked) {
        _live.remove(session);
        unawaited(session.close());
      }
    }
  }

  /// A parked session for [spec] whose conversation [conversation] continues,
  /// and how much of it the session has seen.
  (CliSession?, int) _take(CliSessionSpec spec, List<LlmMessage> conversation) {
    for (final parked in _idle.reversed) {
      final seen = parked.seen;
      if (!parked.session.alive ||
          !parked.session.spec.sameAs(spec) ||
          seen.length >= conversation.length) {
        continue;
      }
      if (!seen.indexed.every((e) => e.$2 == markOf(conversation[e.$1]))) {
        continue;
      }
      final rest = conversation.sublist(seen.length);
      if (!parked.session.accepts(rest)) continue;
      _idle.remove(parked);
      parked.timer.cancel();
      return (parked.session, seen.length);
    }
    return (null, 0);
  }

  void _park(CliSession session, List<MessageMark> seen) {
    late final _Parked parked;
    parked = _Parked(
      session,
      seen,
      Timer(idleFor, () {
        if (_idle.remove(parked)) _retire(session);
      }),
    );
    _idle.add(parked);
    while (_idle.length > maxIdle) {
      final oldest = _idle.removeAt(0);
      oldest.timer.cancel();
      _retire(oldest.session);
    }
  }

  void _retire(CliSession session) {
    _live.remove(session);
    unawaited(
      session.close().catchError(
        (Object e) => logFailure("llm", "closing a CLI session failed", e),
      ),
    );
  }

  @override
  void close() {
    _closed = true;
    for (final parked in _idle) {
      parked.timer.cancel();
    }
    _idle.clear();
    for (final session in _live.toList()) {
      _retire(session);
    }
  }

  /// What of [message] decides whether a session saw it, compared with `==`
  /// against the message as the loop sends it back. Not every field: the loop
  /// keeps what it was given, but the reasoning it keeps is its own and the
  /// text may be trimmed, so the ids decide where there are any. A parked
  /// session holds these rather than the messages, so it keeps no
  /// attachment's bytes alive.
  static MessageMark markOf(LlmMessage message) => (
    role: message.role,
    toolCallId: message.toolCallId,
    calls: [for (final c in message.toolCalls) c.id].join("\n"),
    text: message.role == LlmRole.assistant
        ? message.text.trim()
        : message.text,
  );
}

/// What [CliClient.markOf] keeps of a message.
typedef MessageMark = ({
  LlmRole role,
  String? toolCallId,
  String calls,
  String text,
});

class _Parked {
  _Parked(this.session, this.seen, this.timer);

  final CliSession session;
  final List<MessageMark> seen;
  final Timer timer;
}

/// A message a program is sent as user input: what follows a reply, rather
/// than a reply or its results.
bool fromUser(LlmMessage m) =>
    m.role == LlmRole.user || m.role == LlmRole.system;

/// What a fresh session is first told: [rest] split into the [history] it
/// is told as a [transcriptOf], and the trailing user turns, sent as
/// themselves. With no such turns, [carryOn] is the message instead.
({List<LlmMessage> history, List<LlmMessage> tail}) splitTail(
  List<LlmMessage> rest,
) {
  final cut = rest.lastIndexWhere((m) => !fromUser(m)) + 1;
  return (history: rest.sublist(0, cut), tail: rest.sublist(cut));
}

const carryOn = "Carry on from where the conversation leaves off.";

/// Whether [rest] is the results of exactly the calls [ids], each once.
bool answersAll(List<LlmMessage> rest, List<String> ids) =>
    rest.length == ids.length &&
    rest.every((m) => m.role == LlmRole.tool) &&
    const SetEquality<String?>().equals({
      for (final m in rest) m.toolCallId,
    }, ids.toSet());

/// The loop's effort word as one the programs take, which is the loop's own
/// less `minimal`.
String? effortOf(String? effort) => switch (effort) {
  "minimal" => "low",
  "low" || "medium" || "high" || "xhigh" || "max" => effort,
  _ => null,
};

/// [history] written out as text, for a session that starts part-way through
/// a conversation: a program takes a new message, not a past it did not live
/// through, so the past is told to it.
String transcriptOf(List<LlmMessage> history) {
  final out = StringBuffer(
    "The conversation so far, which you are continuing as the assistant. "
    "Tool calls in it were made and answered already; make new ones with "
    "your tools.\n\n<conversation>\n",
  );
  for (final message in history) {
    final files = [
      for (final file in message.attachments) "[attached: ${file.filename}]",
    ].join(" ");
    switch (message.role) {
      case LlmRole.system:
        out.writeln("System: ${message.text}");
      case LlmRole.user:
        out.writeln("User: ${message.text} $files".trimRight());
      case LlmRole.assistant:
        if (message.text.isNotEmpty) out.writeln("Assistant: ${message.text}");
        for (final call in message.toolCalls) {
          out.writeln(
            "Assistant called ${call.name} (${call.id}) with "
            "${call.argumentsJson}",
          );
        }
      case LlmRole.tool:
        out.writeln(
          "Result of ${message.toolCallId}: ${message.text} $files".trimRight(),
        );
    }
    out.writeln();
  }
  out.write("</conversation>");
  return out.toString();
}

/// What a session needs of the program it runs: its output a line at a
/// time, a way to write to it, and its end. The port a test fakes;
/// [launchProcess] is the real one.
abstract class CliProcess {
  /// Its standard output, one line per event.
  Stream<String> get lines;

  /// Its standard error, as it comes.
  Stream<String> get errors;

  /// [text] to its standard input, as it is.
  void write(String text);

  /// [line] and the end of one.
  void writeLine(String line) => write("$line\n");

  /// Closes its standard input, which a program reading it takes as the end.
  Future<void> closeInput();

  Future<int> get exitCode;

  /// SIGTERM, or SIGKILL where [force].
  void kill({bool force = false});
}

/// How long a closing program is given to go on its own, once its stdin is
/// closed, and then again after a SIGTERM.
const _grace = Duration(seconds: 3);

/// Ends [process]: stdin closed first, which a program reading it takes as
/// the end, then SIGTERM, then SIGKILL, [_grace] apart.
Future<void> stopProcess(CliProcess process, String name) async {
  Future<bool> exited() => process.exitCode
      .then((_) => true)
      .timeout(_grace, onTimeout: () => false);
  try {
    await process.closeInput().timeout(_grace, onTimeout: () {});
  } on Object catch (e) {
    logFailure("llm", "closing $name's input failed", e);
  }
  if (await exited()) return;
  process.kill();
  if (!await exited()) process.kill(force: true);
}

/// The last of what a program said on stderr, for an exit to explain itself.
class StderrTail {
  static const _keep = 4000;

  final _buffer = StringBuffer();

  void add(String text) {
    _buffer.write(text);
    final over = _buffer.length - _keep;
    if (over <= 0) return;
    final kept = _buffer.toString().substring(over);
    _buffer
      ..clear()
      ..write(kept);
  }

  @override
  String toString() => _buffer.toString().trim();
}

/// How a session starts its program.
typedef LaunchCli =
    Future<CliProcess> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
    });

/// [executable] run as a process of this machine, with [environment] and
/// nothing else of the app's.
Future<CliProcess> launchProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) async => _IoCliProcess(
  await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
    // npm installs a `.cmd` shim on Windows, which only a shell runs.
    runInShell:
        Platform.isWindows &&
        const [".cmd", ".bat"].contains(p.extension(executable).toLowerCase()),
  ),
);

class _IoCliProcess extends CliProcess {
  _IoCliProcess(this._process);

  final Process _process;

  @override
  Stream<String> get lines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get errors => _process.stderr.transform(utf8.decoder);

  @override
  void write(String text) => _process.stdin.write(text);

  @override
  Future<void> closeInput() => _process.stdin.close();

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill({bool force = false}) =>
      _process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
}
