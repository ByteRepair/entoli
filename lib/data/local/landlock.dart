import "dart:async";
import "dart:io";

import "package:path/path.dart" as p;

import "../../domain/shell.dart";

/// Landlock confinement for one command, on the machine itself.
///
/// Landlock is a kernel security module (Linux 5.13+) a process uses to
/// restrict its own descendants: a ruleset of allowed access is applied to
/// the calling process and inherited by everything it spawns, and cannot be
/// loosened afterwards. It needs no root, no namespace, no mount, and no
/// setuid helper — which is why it is the confinement a desktop agent can
/// apply per command, where a namespace tool needs a binary and a userns the
/// OS may refuse to grant.
///
/// The ruleset here is the allowlist shape: read everywhere, write only the
/// workspace and tmp. `$HOME`'s profile files — `.bashrc`, `.gitconfig`,
/// `.ssh`, the whole deny-write set — fall outside the granted write set
/// without being named, which is the point of granting by subtree rather
/// than by file.
///
/// The ruleset is applied by a small C helper compiled once into the app's
/// cache directory. The ruleset attaches to the process that creates it and
/// is inherited by its children, so the process that restricts must be the
/// command's ancestor; `Process.start` cannot apply one before execing, and
/// the agent's own process must not be restricted (the file tools and the
/// chat store are not part of a command's write set). The helper does the
/// three syscalls — create the ruleset, add the rules, restrict self — and
/// execs the command's shell.
///
/// Where Landlock is not available — an older kernel, a machine without a C
/// compiler — [prefixFor] answers null and the caller fails the command
/// closed. A confinement-requiring command is never run unrestricted.
class LandlockSandboxHelper implements SandboxHelper {
  LandlockSandboxHelper({required this.cacheDir});

  /// Where the compiled helper lives, beside the app's other laid-out tools.
  final String cacheDir;

  static const _binaryName = "entoli-landlock";

  String? _binary;

  /// Whether the helper is known good. Learned once, by trying: a machine
  /// without a compiler or an old kernel pays one failed attempt and then
  /// fails closed from then on, rather than per command.
  bool _attempted = false;

  @override
  Future<List<String>?> prefixFor(CommandSandbox sandbox) async {
    final binary = await _ensureBinary();
    if (binary == null) return null;
    return [
      binary,
      "exec",
      "--workspace",
      sandbox.workspace,
      if (sandbox.tmp != null) ...["--tmp", sandbox.tmp!],
      if (sandbox.home != null) ...["--home", sandbox.home!],
      for (final dir in sandbox.extraWrites) ...["--write", dir],
      "--",
    ];
  }

  /// Compiles the helper the first command that needs it, from the source
  /// embedded below. `cc` is what every desktop Linux that runs this app
  /// has; the answer is cached for the app's lifetime, and a failed compile
  /// is remembered the same way — the caller sees null and fails closed.
  Future<String?> _ensureBinary() async {
    if (_binary != null) return _binary;
    if (_attempted) return null;
    _attempted = true;
    final binaryPath = p.join(cacheDir, _binaryName);
    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final sourcePath = "$binaryPath.c";
      File(sourcePath).writeAsStringSync(helperSource);
      final result = await Process.run("cc", [
        "-O2",
        "-o",
        binaryPath,
        sourcePath,
      ]);
      if (result.exitCode != 0 || !File(binaryPath).existsSync()) return null;
      _binary = binaryPath;
      return binaryPath;
    } on Exception {
      return null;
    }
  }
}

/// The helper's source, compiled by [LandlockSandboxHelper._ensureBinary].
///
/// The ABI is read forward: the kernel advertises the best version it has,
/// the helper asks for it and takes the access rights the answer says exist
/// (truncate from ABI 3), and a kernel older than Landlock itself fails the
/// setup with exit 91 — the fail-closed half of the contract. Handling
/// truncate matters as much as granting it: a ruleset that does not handle a
/// right leaves it free, and `> file` on a read-only grant would truncate
/// anyway without ABI 3.
const helperSource = r"""
/* entoli-landlock: run a command confined by Landlock — read everywhere,
 * write only the paths given. Usage:
 *   entoli-landlock exec --workspace DIR [--tmp DIR] [--home DIR]
 *                    [--write DIR]... -- CMD...
 * Exit 91 where Landlock cannot be set up; the caller fails closed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 7)
#endif

/* Exit 91: the caller's answer to a confinement that did not happen. */
static int unusable(const char *what) {
  fprintf(stderr, "entoli-landlock: %s: %s\n", what, strerror(errno));
  return 91;
}

static int add_rule(int ruleset_fd, const char *path, __u64 access) {
  int fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) return -1;
  struct landlock_path_beneath_attr rule;
  memset(&rule, 0, sizeof(rule));
  rule.allowed_access = access;
  rule.parent_fd = fd;
  int err = syscall(SYS_landlock_add_rule, ruleset_fd,
                    LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
  close(fd);
  return err;
}

int main(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "exec") != 0) {
    fprintf(stderr, "usage: entoli-landlock exec --workspace DIR [--tmp DIR]"
                    " [--home DIR] -- CMD...\n");
    return 2;
  }
  const char *workspace = NULL, *tmp = NULL, *home = NULL;
  const char *extra[argc];
  int extras = 0;
  int i = 2;
  while (i < argc && strcmp(argv[i], "--") != 0) {
    if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", argv[i]); return 2; }
    if (!strcmp(argv[i], "--workspace")) workspace = argv[++i];
    else if (!strcmp(argv[i], "--tmp")) tmp = argv[++i];
    else if (!strcmp(argv[i], "--home")) home = argv[++i];
    else if (!strcmp(argv[i], "--write")) {
      extra[extras++] = argv[++i];
    }
    else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    i++;
  }
  if (!workspace || i + 3 >= argc) {
    fprintf(stderr, "usage: entoli-landlock exec --workspace DIR -- CMD...\n");
    return 2;
  }

  /* The ABI the kernel speaks: 0 or an error where there is no Landlock. */
  int abi = syscall(SYS_landlock_create_ruleset, NULL, 0,
                    LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) {
    fprintf(stderr, "entoli-landlock: kernel has no Landlock (ABI %d)\n", abi);
    return 91;
  }

  /* Handled = everything a command could do to a file that this ruleset
   * decides about. A right not handled here is a right every rule grants by
   * omission, so the set is "everything this kernel can express that is not
   * a read": the ABI-1 write and make rights plus execute, with truncate
   * added where the kernel answers for it. MAKE_REG and MAKE_SYM are the
   * ones a first draft of this ruleset missed, and their omission is a hole
   * a confined command could walk through: creating a file or a symlink
   * anywhere (a link whose target only matters when something writes through
   * it, but a link at a well-known path is already a footgun) is a make, and
   * an unhandled make is granted everywhere. REFER (ABI 2) is left unhandled
   * on purpose: it governs cross-hierarchy links and renames, its rules are
   * pairwise, and a workspace that cannot link into itself would break git. */
  __u64 handled = LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |
      LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
      LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE |
      LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR |
      LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SYM |
      LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SOCK |
      LANDLOCK_ACCESS_FS_MAKE_FIFO;
  if (abi >= 3) handled |= LANDLOCK_ACCESS_FS_TRUNCATE;

  struct landlock_ruleset_attr attr;
  memset(&attr, 0, sizeof(attr));
  attr.handled_access_fs = handled;
  int ruleset_fd = syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (ruleset_fd < 0) {
    fprintf(stderr, "entoli-landlock: create ruleset: %s\n", strerror(errno));
    return 91;
  }

  /* Read everywhere. The write rights are not in this grant, so a write
   * outside the granted hierarchies is EACCES — including HOME's profile
   * files, which the granted set never names. */
  __u64 read_rights = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
      LANDLOCK_ACCESS_FS_EXECUTE;
  if (add_rule(ruleset_fd, "/", read_rights) != 0) {
    fprintf(stderr, "entoli-landlock: rule /: %s\n", strerror(errno));
    return 91;
  }
  /* Write the workspace and tmp: every right the ruleset handles. */
  __u64 write_rights = handled;
  if (add_rule(ruleset_fd, workspace, write_rights) != 0) {
    fprintf(stderr, "entoli-landlock: rule %s: %s\n", workspace, strerror(errno));
    return 91;
  }
  if (tmp && add_rule(ruleset_fd, tmp, write_rights) != 0) {
    fprintf(stderr, "entoli-landlock: rule %s: %s\n", tmp, strerror(errno));
    return 91;
  }
  /* /dev/null is where commands throw output away, git among them (it opens
   * it read-write). Granting write here grants nothing useful — what is
   * written to /dev/null is gone — and refusing it breaks every command
   * that redirects there. It is a character device, so the directory and
   * make rights are not grantable on it: file rights alone. */
  __u64 devnull_rights = LANDLOCK_ACCESS_FS_WRITE_FILE;
  if (abi >= 3) devnull_rights |= LANDLOCK_ACCESS_FS_TRUNCATE;
  if (add_rule(ruleset_fd, "/dev/null", devnull_rights) != 0) {
    fprintf(stderr, "entoli-landlock: rule /dev/null: %s\n", strerror(errno));
    return 91;
  }
  /* HOME is readable by the rule on / and named here only for the record;
   * granting it read again costs one rule and documents the boundary. */
  if (home && add_rule(ruleset_fd, home, read_rights) != 0) {
    fprintf(stderr, "entoli-landlock: rule %s: %s\n", home, strerror(errno));
    return 91;
  }
  /* The extra writable roots — the directories a permission rule or the
   * project's settings name as part of the work. One can name a FILE, and
   * the kernel refuses to grant
   * directory rights on a non-directory fd — every such add_rule fails and
   * the ruleset never comes up. A file gets the file rights alone. */
  for (int e = 0; e < extras; e++) {
    __u64 rights = write_rights;
    struct stat st;
    if (stat(extra[e], &st) == 0 && !S_ISDIR(st.st_mode)) {
      rights = LANDLOCK_ACCESS_FS_WRITE_FILE;
      if (abi >= 3) rights |= LANDLOCK_ACCESS_FS_TRUNCATE;
    }
    if (add_rule(ruleset_fd, extra[e], rights) != 0) {
      fprintf(stderr, "entoli-landlock: rule %s: %s\n", extra[e], strerror(errno));
      return 91;
    }
  }

  /* No-new-privs is required before restrict_self, and is its own guarantee:
   * the command cannot exec its way around the ruleset with a setuid binary. */
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    fprintf(stderr, "entoli-landlock: no_new_privs: %s\n", strerror(errno));
    return 91;
  }
  if (syscall(SYS_landlock_restrict_self, ruleset_fd, 0) != 0) {
    fprintf(stderr, "entoli-landlock: restrict: %s\n", strerror(errno));
    return 91;
  }
  close(ruleset_fd);

  char **cmd = &argv[i + 1];
  execvp(cmd[0], cmd);
  fprintf(stderr, "entoli-landlock: exec %s: %s\n", cmd[0], strerror(errno));
  return 127;
}
""";
