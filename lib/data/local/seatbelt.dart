import "dart:io";

import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/shell.dart";

/// Seatbelt confinement for one command, on a Mac.
///
/// Seatbelt is the kernel sandbox under `sandbox_init(3)`, and
/// `/usr/bin/sandbox-exec` is its front door: it applies a profile to itself
/// and execs the command, which inherits it, and nothing inside can loosen it.
/// That is Landlock's contract — an unprivileged process restricting its own
/// descendants — so this answers the same [SandboxHelper] slot with the same
/// ruleset: read everywhere, write only the workspace, tmp, the system's temp
/// folders and the granted directories. Nothing changes a live profile; each confined command gets
/// one built from its own [CommandSandbox], which is how a grant made
/// mid-chat reaches the next command.
///
/// `sandbox-exec` is marked deprecated and has been for a decade; Apple's own
/// services still run on the same mechanism. It ships with macOS, so unlike
/// Landlock's helper nothing is compiled — it is probed once, and where it
/// will not apply a profile [prefixFor] answers null and the caller fails
/// the command closed. A process already under App Sandbox cannot take a
/// second profile, which is the probe's other failure.
class SeatbeltSandboxHelper implements SandboxHelper {
  SeatbeltSandboxHelper({
    this.binary = "/usr/bin/sandbox-exec",
    this.systemTemps,
  });

  final String binary;

  /// The machine's own temp folders, granted to every confined command:
  /// `/private/tmp` and the per-user folder under `/var/folders`. `TMPDIR`
  /// still names the chat's own tmp, but the tools a build reaches for most
  /// do not ask it: `mktemp` prefers the per-user folder
  /// (`_CS_DARWIN_USER_TEMP_DIR`) to `TMPDIR`, as its manual says, and the
  /// system's bash 3.2 writes a here document to `/var/tmp` or `/tmp` and
  /// else the working directory, never to `TMPDIR`. Denied, each failed
  /// wherever the command stood outside the workspace. Null asks the machine;
  /// a test that needs an outside under the temp root passes none.
  final List<String>? systemTemps;

  /// Learned once, by trying, for the reason Landlock's compile is.
  bool? _usable;

  List<String>? _discovered;

  @override
  Future<List<String>?> prefixFor(CommandSandbox sandbox) async {
    if (!await _probe()) return null;
    final writes = [
      sandbox.workspace,
      if (sandbox.tmp != null) sandbox.tmp!,
      ...(systemTemps ?? await _machineTemps()),
      ...sandbox.extraWrites,
    ];
    return [
      binary,
      "-p",
      seatbeltProfile(writes.length),
      for (final (i, path) in writes.indexed) ...[
        "-D",
        "W$i=${realPath(path)}",
      ],
      "--",
    ];
  }

  /// `/private/tmp` rather than `/tmp`, which is a symlink [realPath] would
  /// resolve anyway, and the per-user folder as `getconf` names it, asked
  /// once: it is fixed for the user, and the app runs as the same user its
  /// commands do. A `getconf` that will not answer leaves `/private/tmp`.
  Future<List<String>> _machineTemps() async {
    if (_discovered != null) return _discovered!;
    String? user;
    try {
      final result = await Process.run("/usr/bin/getconf", [
        "DARWIN_USER_TEMP_DIR",
      ]);
      final out = "${result.stdout}".trim();
      if (result.exitCode == 0 && out.isNotEmpty) {
        user = out;
      } else {
        logFailure(
          "sandbox",
          "the per-user temp folder is not known",
          "getconf exited ${result.exitCode}",
        );
      }
    } on Exception catch (e) {
      logFailure("sandbox", "the per-user temp folder is not known", "$e");
    }
    return _discovered = ["/private/tmp", ?user];
  }

  Future<bool> _probe() async {
    if (_usable != null) return _usable!;
    try {
      final result = await Process.run(binary, [
        "-p",
        seatbeltProfile(0),
        "--",
        "/usr/bin/true",
      ]);
      _usable = result.exitCode == 0;
    } on Exception {
      _usable = false;
    }
    return _usable!;
  }
}

/// The profile for [writes] granted directories, read from parameters `W0`
/// onward. The paths travel as `-D` parameters rather than in the source, so
/// a quote or a bracket in a directory name cannot change what the profile
/// says. A parameter the profile names and the command line does not is a
/// profile error, which is why the count is the profile's.
///
/// `subpath` grants a file as well as a directory, so a rule naming a file
/// needs no case of its own. The devices are where commands throw output away
/// or talk to their terminal; writing to them grants nothing a file would.
String seatbeltProfile(int writes) {
  final grants = [
    for (var i = 0; i < writes; i++) '(subpath (param "W$i"))',
    '(literal "/dev/null")',
    '(literal "/dev/zero")',
    '(literal "/dev/dtracehelper")',
    r'(regex #"^/dev/tty")',
    r'(regex #"^/dev/fd/")',
  ];
  return "(version 1)\n"
      "(allow default)\n"
      "(deny file-write*)\n"
      "(allow file-write*\n  ${grants.join("\n  ")})\n";
}

/// [path] with its symlinks resolved, since Seatbelt matches the path the
/// kernel resolved: a grant of `/tmp/x` matches nothing, every write there
/// landing at `/private/tmp/x`. A path not there yet resolves its nearest
/// existing ancestor and keeps the rest as written.
String realPath(String path) {
  var head = p.normalize(p.absolute(path));
  final tail = <String>[];
  while (true) {
    try {
      return p.joinAll([Directory(head).resolveSymbolicLinksSync(), ...tail]);
    } on FileSystemException {
      final parent = p.dirname(head);
      if (parent == head) return p.normalize(p.absolute(path));
      tail.insert(0, p.basename(head));
      head = parent;
    }
  }
}
