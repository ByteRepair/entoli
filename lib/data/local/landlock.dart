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
  static const _reportName = "entoli-deny-report.so";

  String? _binary;
  String? _report;

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
      "--workspace", sandbox.workspace,
      if (sandbox.tmp != null) ...["--tmp", sandbox.tmp!],
      if (sandbox.home != null) ...["--home", sandbox.home!],
      for (final dir in sandbox.extraWrites) ...["--write", dir],
      "--",
    ];
  }

  @override
  String? get reportShimPath => _report;

  @override
  String? reportPathFor(CommandSandbox sandbox) {
    // Under the grant — the sandboxed tmp when there is one, the workspace
    // otherwise — or the shim could not write the report it exists to
    // write. The shim degrades to silence where the file cannot be made;
    // the prose cross-check takes over, and says so in the log.
    final report = _report;
    if (report == null) return null;
    final path = sandbox.tmp ?? sandbox.workspace;
    return "$path/.entoli-deny-report";
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
      final result = await Process.run("cc", ["-O2", "-o", binaryPath, sourcePath]);
      if (result.exitCode != 0 || !File(binaryPath).existsSync()) return null;
      _binary = binaryPath;
      // The report shim beside it, best-effort: a compile that fails leaves
      // the report channel null and the prose cross-check answers instead.
      final reportPath = p.join(cacheDir, _reportName);
      final reportSourcePath = p.join(cacheDir, "$_reportName.c");
      File(reportSourcePath).writeAsStringSync(reportShimSource);
      final shim = await Process.run(
          "cc", ["-O2", "-shared", "-fPIC", "-o", reportPath,
              reportSourcePath, "-ldl"]);
      if (shim.exitCode == 0 && File(reportPath).existsSync()) {
        _report = reportPath;
      }
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
   * project's settings name as part of the work. A denial report can name a
   * FILE (the exact path the write touched), and the kernel refuses to grant
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

  /* The report shim beside it, when one was built: LD_PRELOAD loads it into
   * every command the shell goes on to run, and ENTOLI_REPORT names the file
   * the denials are written to. The report file is made by the caller inside
   * the grant — usually the sandboxed tmp — so the shim's own writes land.
   * Either variable unset means no report channel, which is honest; the
   * shim is best-effort beside the enforcement, never load-bearing for it. */
  const char *report = getenv("ENTOLI_REPORT_PATH");
  if (report != NULL && report[0] != '\0') {
    const char *preload = getenv("ENTOLI_REPORT_SO");
    if (preload != NULL && preload[0] != '\0') {
      setenv("LD_PRELOAD", preload, 1);
      setenv("ENTOLI_REPORT", report, 1);
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

/// The report shim's source, compiled beside the helper by the same
/// best-effort flow. Interposes the libc calls a write goes through and
/// records, one line per denial (`op\tpath`), every syscall the kernel
/// refused with EACCES/EPERM/EROFS — the operation the command was about,
/// not the prose a failing tool chose to print about it. Enforcement is
/// Landlock's alone; the shim only says what was denied.
///
/// The path is absolute and names what Landlock checked: the file for a
/// content write, the directory for an entry made in or removed from it.
/// `mkdir -p` changes into each parent and makes the next by its bare name,
/// so a path reported as the call gave it was resolved against the wrong
/// directory and filtered out as inside the grant; and a grant to a
/// directory that does not exist yet is one the helper refuses outright.
///
/// Two load-bearing details the code shows and the comment keeps:
/// the real symbols are resolved at load and the report is written with
/// raw syscalls, because the interposed `open` would see the report file's
/// own EACCES — it usually sits outside the grant — and recurse forever;
/// that segfault is what the first confined run taught. And every failure
/// of the shim itself falls back to the real call, so a report channel
/// that cannot work degrades to silence, never to a broken command.
const reportShimSource = r"""
/* entoli-deny-report: LD_PRELOAD shim that reports filesystem denials.
 *
 * What it is for: the sandbox denies a syscall at the kernel and the only
 * trace was the command's own prose about it — a wording per tool, matched
 * by regex, and every wording nobody had thought of was a denial nothing
 * reported. The shim interposes the libc calls a write goes through and
 * records the syscall the kernel actually refused: which operation, on
 * which path, with which errno. Enforcement stays with Landlock; this only
 * says what was denied, whatever the failing program chooses to print.
 *
 * Ground rules of the shim, load-bearing:
 * - It never changes an outcome. After the real call returns, a denial is
 *   recorded and the caller's errno is left exactly as the real call left
 *   it. A shim failure falls back to the real call and stays silent:
 *   reporting degrades to nothing, never to a broken command.
 * - It filters nothing. Every denial is written; the reader in Dart owns
 *   the inside/outside policy, which keeps the grant in one place.
 *
 * The report is one line per denial, "op\tpath\n", appended to the file
 * named by $ENTOLI_REPORT. O_APPEND makes one line one atomic write, so
 * concurrent commands in one report cannot interleave mid-line. A failed
 * write is dropped — best-effort beside a denial the kernel answered.
 *
 * The ops are what Landlock decides: "write" (a file's content, the path
 * the file), "make" and "remove" (an entry, the path the directory it is
 * in), and "read", "exec", "chmod" — which the ruleset grants everywhere or
 * does not handle, so a denial of one is the file's own permissions.
 *
 * The real symbols are resolved once at load (a constructor), not per call:
 * a miss leaves the pointer null and the wrapper passes through to the
 * real call failing on its own — there is no path where the shim substitutes
 * its own failure for the command's.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

static int (*real_open)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_creat)(const char *, mode_t);
static FILE *(*real_fopen)(const char *, const char *);
static int (*real_mkdir)(const char *, mode_t);
static int (*real_mkdirat)(int, const char *, mode_t);
static int (*real_mknod)(const char *, mode_t, dev_t);
static int (*real_mknodat)(int, const char *, mode_t, dev_t);
static int (*real_unlink)(const char *);
static int (*real_unlinkat)(int, const char *, int);
static int (*real_rmdir)(const char *);
static int (*real_rename)(const char *, const char *);
static int (*real_renameat)(int, const char *, int, const char *);
static int (*real_renameat2)(int, const char *, int, const char *, unsigned);
static int (*real_link)(const char *, const char *);
static int (*real_linkat)(int, const char *, int, const char *, int);
static int (*real_symlink)(const char *, const char *);
static int (*real_symlinkat)(const char *, int, const char *);
static int (*real_truncate)(const char *, off_t);
static int (*real_fchmodat)(int, const char *, mode_t, int);
static int (*real_execve)(const char *, char *const[], char *const[]);
/* The large-file names: an LFS build (every modern one — git's ref locks
 * here went through open64) binds these, and without interposing them the
 * plain wrappers see nothing of its denials. */
static int (*real_open64)(const char *, int, ...);
static int (*real_openat64)(int, const char *, int, ...);
static int (*real_creat64)(const char *, mode_t);
static FILE *(*real_fopen64)(const char *, const char *);
static int (*real_truncate64)(const char *, off_t);
/* The fortified names: a _FORTIFY_SOURCE build (coreutils on Fedora) binds
 * these for an open with no mode, and they reach the kernel through libc's
 * internal open rather than the interposed one. */
static int (*real___open_2)(const char *, int);
static int (*real___open64_2)(const char *, int);
static int (*real___openat_2)(int, const char *, int);
static int (*real___openat64_2)(int, const char *, int);

/* Resolved at load time, before any command runs. A symbol libc does not
 * export is left null; the wrapper checks. */
__attribute__((constructor)) static void resolve_reals(void) {
  real_open = dlsym(RTLD_NEXT, "open");
  real_openat = dlsym(RTLD_NEXT, "openat");
  real_creat = dlsym(RTLD_NEXT, "creat");
  real_fopen = dlsym(RTLD_NEXT, "fopen");
  real_mkdir = dlsym(RTLD_NEXT, "mkdir");
  real_mkdirat = dlsym(RTLD_NEXT, "mkdirat");
  real_mknod = dlsym(RTLD_NEXT, "mknod");
  real_mknodat = dlsym(RTLD_NEXT, "mknodat");
  real_unlink = dlsym(RTLD_NEXT, "unlink");
  real_unlinkat = dlsym(RTLD_NEXT, "unlinkat");
  real_rmdir = dlsym(RTLD_NEXT, "rmdir");
  real_rename = dlsym(RTLD_NEXT, "rename");
  real_renameat = dlsym(RTLD_NEXT, "renameat");
  real_renameat2 = dlsym(RTLD_NEXT, "renameat2");
  real_link = dlsym(RTLD_NEXT, "link");
  real_linkat = dlsym(RTLD_NEXT, "linkat");
  real_symlink = dlsym(RTLD_NEXT, "symlink");
  real_symlinkat = dlsym(RTLD_NEXT, "symlinkat");
  real_truncate = dlsym(RTLD_NEXT, "truncate");
  real_fchmodat = dlsym(RTLD_NEXT, "fchmodat");
  real_execve = dlsym(RTLD_NEXT, "execve");
  real_open64 = dlsym(RTLD_NEXT, "open64");
  real_openat64 = dlsym(RTLD_NEXT, "openat64");
  real_creat64 = dlsym(RTLD_NEXT, "creat64");
  real_fopen64 = dlsym(RTLD_NEXT, "fopen64");
  real_truncate64 = dlsym(RTLD_NEXT, "truncate64");
  real___open_2 = dlsym(RTLD_NEXT, "__open_2");
  real___open64_2 = dlsym(RTLD_NEXT, "__open64_2");
  real___openat_2 = dlsym(RTLD_NEXT, "__openat_2");
  real___openat64_2 = dlsym(RTLD_NEXT, "__openat64_2");
}

static const char *report_path(void) {
  const char *path = getenv("ENTOLI_REPORT");
  return path == NULL || path[0] == '\0' ? NULL : path;
}

/* [path] made absolute against [dirfd], or the cwd for AT_FDCWD, into
 * [out]. Raw syscalls, so nothing here is interposed. A base that cannot be
 * read — a deleted cwd — leaves the path as the call gave it. */
static void absolute(int dirfd, const char *path, char *out, size_t size) {
  if (path == NULL) path = "";
  if (path[0] == '/') {
    snprintf(out, size, "%s", path);
    return;
  }
  char base[4096];
  long n;
  if (dirfd == AT_FDCWD) {
    n = syscall(SYS_getcwd, base, sizeof(base));
  } else {
    char link[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", dirfd);
    n = syscall(SYS_readlinkat, AT_FDCWD, link, base, sizeof(base) - 1);
    if (n > 0) base[n] = '\0';
  }
  if (n <= 0 || base[0] != '/') {
    snprintf(out, size, "%s", path);
    return;
  }
  if (path[0] == '\0') {
    snprintf(out, size, "%s", base);
    return;
  }
  snprintf(out, size, "%s/%s", strcmp(base, "/") == 0 ? "" : base, path);
}

/* [path] cut to the directory it is an entry in. */
static void parent(char *path) {
  size_t len = strlen(path);
  while (len > 1 && path[len - 1] == '/') path[--len] = '\0';
  char *slash = strrchr(path, '/');
  if (slash == NULL) return;
  if (slash == path) slash[1] = '\0';
  else *slash = '\0';
}

/* One denial, "op\tpath". Best-effort: a failed write is dropped. [entry]
 * names the directory [path] is in rather than [path] itself. */
static void report(const char *op, int dirfd, const char *path, int entry) {
  const char *out = report_path();
  if (out == NULL) return;
  char resolved[4096];
  absolute(dirfd, path, resolved, sizeof(resolved));
  if (entry) parent(resolved);
  /* Raw syscalls, not the interposed libc calls: the report file is
   * usually outside the grant, so the interposed open would see its own
   * EACCES and recurse forever — the segfault the first confined run
   * taught. */
  int fd = (int)syscall(SYS_openat, AT_FDCWD, out,
                        O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return;
  char line[4200];
  int n = snprintf(line, sizeof(line), "%s\t%s\n", op, resolved);
  if (n > 0) {
    ssize_t written = syscall(SYS_write, fd, line, (size_t)n);
    (void)written;
  }
  syscall(SYS_close, fd);
}

static int denied(int err) {
  return err == EACCES || err == EPERM || err == EROFS;
}

/* On a denial, record it and put errno back exactly as the real call left
 * it. */
#define REPORT_ON_DENY(op, dirfd, path, entry)                                  \
  do {                                                                          \
    int saved_ = errno;                                                         \
    if (denied(saved_)) report(op, dirfd, path, entry);                         \
    errno = saved_;                                                             \
  } while (0)

/* An open's denial in Landlock's terms. O_TMPFILE makes an unnamed file in
 * the directory it names; O_CREAT makes an entry where there was none and
 * writes the file where there was one; any other write access writes it. */
static void report_open(int dirfd, const char *path, int flags) {
  int saved = errno;
  if (!denied(saved)) return;
  if ((flags & O_TMPFILE) == O_TMPFILE) {
    report("make", dirfd, path, 0);
  } else if (flags & O_CREAT) {
    int exists = syscall(SYS_faccessat, dirfd, path, F_OK) == 0;
    report(exists ? "write" : "make", dirfd, path, !exists);
  } else if ((flags & O_ACCMODE) != O_RDONLY || (flags & O_TRUNC)) {
    report("write", dirfd, path, 0);
  } else {
    report("read", dirfd, path, 0);
  }
  errno = saved;
}

/* fopen's mode as the open flags it stands for. */
static int fopen_flags(const char *mode) {
  if (mode == NULL) return O_RDONLY;
  int plus = strchr(mode, '+') != NULL;
  switch (mode[0]) {
    case 'w': return (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
    case 'a': return (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
    default: return plus ? O_RDWR : O_RDONLY;
  }
}

#define GUARD(real_ptr)                                                        \
  if (real_ptr == NULL) {                                                       \
    errno = ENOSYS;                                                             \
    return -1;                                                                  \
  }

#define GUARD_FILE(real_ptr)                                                   \
  if (real_ptr == NULL) {                                                       \
    errno = ENOSYS;                                                             \
    return NULL;                                                                \
  }

#define OPEN_MODE(flags, mode)                                                 \
  mode_t mode = 0;                                                              \
  if (flags & (O_CREAT | O_TMPFILE)) {                                          \
    va_list ap;                                                                 \
    va_start(ap, flags);                                                        \
    mode = va_arg(ap, int);                                                     \
    va_end(ap);                                                                 \
  }

int open(const char *path, int flags, ...) {
  GUARD(real_open)
  OPEN_MODE(flags, mode)
  int rc = real_open(path, flags, mode);
  if (rc < 0) report_open(AT_FDCWD, path, flags);
  return rc;
}

int open64(const char *path, int flags, ...) {
  GUARD(real_open64)
  OPEN_MODE(flags, mode)
  int rc = real_open64(path, flags, mode);
  if (rc < 0) report_open(AT_FDCWD, path, flags);
  return rc;
}

int openat(int dirfd, const char *path, int flags, ...) {
  GUARD(real_openat)
  OPEN_MODE(flags, mode)
  int rc = real_openat(dirfd, path, flags, mode);
  if (rc < 0) report_open(dirfd, path, flags);
  return rc;
}

int openat64(int dirfd, const char *path, int flags, ...) {
  GUARD(real_openat64)
  OPEN_MODE(flags, mode)
  int rc = real_openat64(dirfd, path, flags, mode);
  if (rc < 0) report_open(dirfd, path, flags);
  return rc;
}

int __open_2(const char *path, int flags) {
  GUARD(real___open_2)
  int rc = real___open_2(path, flags);
  if (rc < 0) report_open(AT_FDCWD, path, flags);
  return rc;
}

int __open64_2(const char *path, int flags) {
  GUARD(real___open64_2)
  int rc = real___open64_2(path, flags);
  if (rc < 0) report_open(AT_FDCWD, path, flags);
  return rc;
}

int __openat_2(int dirfd, const char *path, int flags) {
  GUARD(real___openat_2)
  int rc = real___openat_2(dirfd, path, flags);
  if (rc < 0) report_open(dirfd, path, flags);
  return rc;
}

int __openat64_2(int dirfd, const char *path, int flags) {
  GUARD(real___openat64_2)
  int rc = real___openat64_2(dirfd, path, flags);
  if (rc < 0) report_open(dirfd, path, flags);
  return rc;
}

int creat(const char *path, mode_t mode) {
  GUARD(real_creat)
  int rc = real_creat(path, mode);
  if (rc < 0) report_open(AT_FDCWD, path, O_CREAT | O_WRONLY | O_TRUNC);
  return rc;
}

int creat64(const char *path, mode_t mode) {
  GUARD(real_creat64)
  int rc = real_creat64(path, mode);
  if (rc < 0) report_open(AT_FDCWD, path, O_CREAT | O_WRONLY | O_TRUNC);
  return rc;
}

FILE *fopen(const char *path, const char *mode) {
  GUARD_FILE(real_fopen)
  FILE *f = real_fopen(path, mode);
  if (f == NULL) report_open(AT_FDCWD, path, fopen_flags(mode));
  return f;
}

FILE *fopen64(const char *path, const char *mode) {
  GUARD_FILE(real_fopen64)
  FILE *f = real_fopen64(path, mode);
  if (f == NULL) report_open(AT_FDCWD, path, fopen_flags(mode));
  return f;
}

int mkdir(const char *path, mode_t mode) {
  GUARD(real_mkdir)
  int rc = real_mkdir(path, mode);
  if (rc < 0) REPORT_ON_DENY("make", AT_FDCWD, path, 1);
  return rc;
}

int mkdirat(int dirfd, const char *path, mode_t mode) {
  GUARD(real_mkdirat)
  int rc = real_mkdirat(dirfd, path, mode);
  if (rc < 0) REPORT_ON_DENY("make", dirfd, path, 1);
  return rc;
}

int mknod(const char *path, mode_t mode, dev_t dev) {
  GUARD(real_mknod)
  int rc = real_mknod(path, mode, dev);
  if (rc < 0) REPORT_ON_DENY("make", AT_FDCWD, path, 1);
  return rc;
}

int mknodat(int dirfd, const char *path, mode_t mode, dev_t dev) {
  GUARD(real_mknodat)
  int rc = real_mknodat(dirfd, path, mode, dev);
  if (rc < 0) REPORT_ON_DENY("make", dirfd, path, 1);
  return rc;
}

int unlink(const char *path) {
  GUARD(real_unlink)
  int rc = real_unlink(path);
  if (rc < 0) REPORT_ON_DENY("remove", AT_FDCWD, path, 1);
  return rc;
}

int unlinkat(int dirfd, const char *path, int flags) {
  GUARD(real_unlinkat)
  int rc = real_unlinkat(dirfd, path, flags);
  if (rc < 0) REPORT_ON_DENY("remove", dirfd, path, 1);
  return rc;
}

int rmdir(const char *path) {
  GUARD(real_rmdir)
  int rc = real_rmdir(path);
  if (rc < 0) REPORT_ON_DENY("remove", AT_FDCWD, path, 1);
  return rc;
}

/* A rename removes an entry from one directory and makes one in another,
 * and the errno does not say which was refused: both are reported, and the
 * reader drops whichever is inside the grant. */
#define REPORT_RENAME(olddirfd, from, newdirfd, to)                            \
  do {                                                                          \
    int saved_ = errno;                                                         \
    if (denied(saved_)) {                                                       \
      report("remove", olddirfd, from, 1);                                      \
      report("make", newdirfd, to, 1);                                          \
    }                                                                           \
    errno = saved_;                                                             \
  } while (0)

int rename(const char *from, const char *to) {
  GUARD(real_rename)
  int rc = real_rename(from, to);
  if (rc < 0) REPORT_RENAME(AT_FDCWD, from, AT_FDCWD, to);
  return rc;
}

int renameat(int olddirfd, const char *from, int newdirfd, const char *to) {
  GUARD(real_renameat)
  int rc = real_renameat(olddirfd, from, newdirfd, to);
  if (rc < 0) REPORT_RENAME(olddirfd, from, newdirfd, to);
  return rc;
}

int renameat2(int olddirfd, const char *from, int newdirfd, const char *to,
              unsigned flags) {
  GUARD(real_renameat2)
  int rc = real_renameat2(olddirfd, from, newdirfd, to, flags);
  if (rc < 0) REPORT_RENAME(olddirfd, from, newdirfd, to);
  return rc;
}

int link(const char *target, const char *path) {
  GUARD(real_link)
  int rc = real_link(target, path);
  if (rc < 0) REPORT_ON_DENY("make", AT_FDCWD, path, 1);
  return rc;
}

int linkat(int olddirfd, const char *target, int newdirfd, const char *path,
           int flags) {
  GUARD(real_linkat)
  int rc = real_linkat(olddirfd, target, newdirfd, path, flags);
  if (rc < 0) REPORT_ON_DENY("make", newdirfd, path, 1);
  return rc;
}

int symlink(const char *target, const char *path) {
  GUARD(real_symlink)
  int rc = real_symlink(target, path);
  if (rc < 0) REPORT_ON_DENY("make", AT_FDCWD, path, 1);
  return rc;
}

int symlinkat(const char *target, int dirfd, const char *path) {
  GUARD(real_symlinkat)
  int rc = real_symlinkat(target, dirfd, path);
  if (rc < 0) REPORT_ON_DENY("make", dirfd, path, 1);
  return rc;
}

int truncate(const char *path, off_t length) {
  GUARD(real_truncate)
  int rc = real_truncate(path, length);
  if (rc < 0) REPORT_ON_DENY("write", AT_FDCWD, path, 0);
  return rc;
}

int truncate64(const char *path, off_t length) {
  GUARD(real_truncate64)
  int rc = real_truncate64(path, length);
  if (rc < 0) REPORT_ON_DENY("write", AT_FDCWD, path, 0);
  return rc;
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
  GUARD(real_fchmodat)
  int rc = real_fchmodat(dirfd, path, mode, flags);
  if (rc < 0) REPORT_ON_DENY("chmod", dirfd, path, 0);
  return rc;
}

int execve(const char *path, char *const argv[], char *const envp[]) {
  GUARD(real_execve)
  int rc = real_execve(path, argv, envp);
  REPORT_ON_DENY("exec", AT_FDCWD, path, 0);
  return rc;
}
""";
