import "dart:async";
import "dart:convert";
import "dart:ffi" show Abi;
import "dart:io";

import "package:flutter/foundation.dart" show protected;
import "package:path/path.dart" as p;
import "package:entoli_core/model/shell.dart"
    show guestHome, guestPath, shellQuoted;
import "package:entoli_core/agent/llm/llm_client.dart" show LlmException;

/// Where a CLI's program runs, and so everything about starting it that
/// differs by platform: which build of it to fetch, what it starts with,
/// how its packages go in, and how a process is made. This machine on a
/// desktop ([HostCliGuest]), Android's Linux under proot, iOS's in the
/// emulator ([LinuxCliGuest]). The app's `CliProvider` reaches its program
/// through this and nothing else.
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

  /// [rootfsDir], the picked Linux's directory, where one is installed; a
  /// start with none is said rather than tried.
  @protected
  static String installed(String? rootfsDir) =>
      rootfsDir ??
      (throw LlmException(
        "No Linux is installed to run it in. Install one from the Terminal "
        "settings.",
      ));

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
