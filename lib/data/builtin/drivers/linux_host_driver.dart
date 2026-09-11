import "dart:async";
import "dart:io";

import "../../../domain/shell.dart";
import "../local_shell.dart" show LocalShell;

/// The home and environment a host command runs under, the static answer for
/// what it does, and the confinement it runs in — the four things issue #230
/// gives a host driver to own. One per operating system was the issue's
/// shape; this build's hosts are Linux (everything below) and Android (no
/// user home to own, no Landlock to apply, the app's own sandbox already
/// around it), so the two live here beside the generic base.
///
/// To the session machinery every driver is still only `commandFor` ending in
/// a shell; the analysis and enforcement here hang off [hostDriver] as
/// optional answers the shell asks for.
class LinuxHostDriver {
  LinuxHostDriver._(this.path, this.loginPath);

  /// The shell this driver runs commands under.
  final String path;

  /// The PATH captured from the user's login shell, or null where the
  /// capture was not made. Null falls back to the inherited environment,
  /// which is today's answer and never a wrong one: the login shell's PATH is
  /// a superset the desktop user expects, not a correction the shell needs.
  final String? loginPath;

  /// The driver the machine's own shell runs under. [shellPath] is the shell
  /// [LocalShell.shellPath] resolved at startup, which is also where the
  /// fallbacks live; [loginPath] the login shell's PATH, captured once per
  /// session by [captureLoginPath] — the caller decides when that cost is
  /// paid, which is why it is not implicit here.
  static ShellDriver? create({
    String? path,
    String? loginPath,
    Toolset? tools,
    bool projectHome = false,
    Map<String, String>? environment,
    String? description,
  }) {
    final shell = path ?? LocalShell.shellPath;
    if (shell == null) return null;
    return ShellDriver(
      commandFor: (cwd, home) => [shell],
      environment: {
        ...?loginPath == null ? null : {"PATH": loginPath},
        ...?environment,
        ...?tools?.environment,
      },
      projectHome: projectHome,
      description: description ??
          (tools?.names != null
              ? "Linux ${Platform.operatingSystemVersion}, commands run under "
                  "$shell, with ${tools!.names} bundled with the app"
              : "Linux ${Platform.operatingSystemVersion}, commands run "
                  "under $shell"),
    );
  }
}

/// Reads the user's login shell's PATH, once per session: the PATH a desktop
/// launcher's process inherits is the system default, missing the
/// directories the user's own profile adds (`~/.local/bin` and friends), so
/// commands run with it fail to find what the user has.
///
/// The capture runs the user's own login shell with a short timeout, and its
/// answer is the whole of the value: a shell whose rc prints anything but the
/// path corrupts the answer, so the line read is the last non-empty one.
///
/// Any failure — no shell of the user's kind on the machine, a profile that
/// hangs, a home without the shell — returns null and the caller uses the
/// inherited PATH, today's behaviour. It never throws.
Future<String?> captureLoginPath({
  String? userHome,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final home = userHome ?? Platform.environment["HOME"];
  if (home == null) return null;

  // Which login shell to ask: SHELL says, and the desktops' own shells are
  // the ones whose profiles add to PATH. A shell that is not one of these is
  // not asked — its profile syntax is unknown, and running a shell we do not
  // know to be a shell is exactly the kind of guess this layer does not make.
  final login = Platform.environment["SHELL"];
  if (login == null) return null;
  final isBourne = login.endsWith("/bash") || login == "bash";
  final isZsh = login.endsWith("/zsh");
  if (!isBourne && !isZsh) return null;
  if (!File(login).existsSync()) return null;

  // `-l` is what makes it a login shell whose profile has run; a
  // non-interactive `-c` run sources nothing interactive, and the same
  // sentence answers for bash and zsh.
  const script = r'echo "$PATH"';
  try {
    final result = await Process.run(login, ["-l", "-c", script],
        environment: {"HOME": home, "PATH": "/usr/bin:/bin"},
        includeParentEnvironment: false)
        .timeout(timeout);
    if (result.exitCode != 0) return null;
    final lines = result.stdout
        .toString()
        .split("\n")
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final path = lines.last;
    if (!path.contains("/")) return null;
    return path;
  } on ProcessException {
    return null;
  } on Exception {
    return null;
  }
}