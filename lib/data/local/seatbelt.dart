import "dart:io";

import "../../domain/shell.dart";

/// Seatbelt confinement for one command, on a Mac.
///
/// Seatbelt is the kernel sandbox under `sandbox_init(3)`, and
/// `/usr/bin/sandbox-exec` is its front door: it applies a profile to itself
/// and execs the command, which inherits it, and nothing inside can loosen it.
/// That is Landlock's contract — an unprivileged process restricting its own
/// descendants — so this answers the same [SandboxHelper] slot with the same
/// ruleset: read everywhere, write only the workspace, tmp and the granted
/// directories. Nothing changes a live profile; each confined command gets
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
  SeatbeltSandboxHelper({this.binary = "/usr/bin/sandbox-exec"});

  final String binary;

  /// Learned once, by trying, for the reason Landlock's compile is.
  bool? _usable;

  @override
  Future<List<String>?> prefixFor(CommandSandbox sandbox) async {
    if (!await _probe()) return null;
    final writes = sandbox.writes;
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
