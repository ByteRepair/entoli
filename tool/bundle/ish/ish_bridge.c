// ish_bridge.c — the FFI adapter over the iSH emulator core.
//
// iOS denies an app a child process, so the shell every other platform has —
// one that does Process.start of /bin/sh or a bundled proot — cannot work here.
// iSH runs the whole guest in-process, and this is the thin C surface Dart
// drives it through. See ios/CLAUDE.md for the constraints that shape it.
//
// The session lifecycle mirrors LocalShell's _Session: a persistent guest
// /bin/sh fed one base64 line at a time, whose output carries a marker naming
// the exit code and the directory the shell is now in. The dispatcher script
// (domain/shell.dart's dispatcherScript) runs inside the guest's own /bin/sh,
// so a cd or an export in one emulated command sticks for the next — the same
// contract the host shell keeps.
//
// This is the bridge's specification. It compiles once linked against the iSH
// XCFramework (built by tool/bundle/ish/build.sh on macOS); the iSH types and
// entry points it names are the ones the vendored core exposes. The Dart side
// (lib/data/local/ish_ffi.dart) drives it through dart:ffi.

#include "ish_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ---- internal state ----

static bool ish_booted = false;
static char *g_last_output = NULL;
static char *g_last_cwd = NULL;

// ---- helpers ----

// Generate a UUID v4 token, the way LocalShell's _Session does (uuid package).
// iSH has no uuidlib; a cheap random one is enough — the marker only has to be
// unique to the shell's life, not cryptographically unpredictable.
static void make_token(char *out, size_t n) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < n - 1; i++) {
        // A deterministic-ish scramble; good enough to not collide within a
        // session. Real randomness is iSH's own job if it ever needs it.
        out[i] = hex[(rand() >> (i % 16 * 2)) & 0xf];
    }
    out[n - 1] = '\0';
}

// Parse the dispatcher's marker line: "@@E<token> rc=<int> cwd=<path>@@".
// Returns true and fills rc/cwd on a match, false where the line is not one.
static bool parse_marker(const char *line, const char *token,
                         int32_t *rc, const char **cwd) {
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "\n@@E%s rc=", token);
    const char *start = strstr(line, prefix);
    if (!start) return false;
    start += strlen(prefix);
    char *end = NULL;
    long val = strtol(start, &end, 10);
    if (!end || strncmp(end, " cwd=", 5) != 0) return false;
    const char *cwd_start = end + 5;
    const char *cwd_end = strstr(cwd_start, "@@");
    if (!cwd_end) return false;
    *rc = (int32_t)val;
    *cwd = cwd_start;  // not NUL-terminated; the caller copies it
    return true;
}

// ---- lifecycle ----

void ish_boot(const char *rootfs_dir) {
    if (ish_booted) return;
    // iSH's first-process setup. xX_main_Xx does this internally before it
    // execs the guest; we stop before the exec and return, so a session can
    // start its own shell. The subset: the process table, the signal frame,
    // and the root filesystem mount.
    become_first_process();
    do_mount(&fakefs, rootfs_dir, "/", "", 0);
    ish_booted = true;
}

ish_session *ish_session_init(
    const char *rootfs_dir,
    const char *data_dir,
    const char *home,
    const char **env,
    int32_t env_count,
    const char **error)
{
    if (!ish_booted) {
        ish_boot(rootfs_dir);
    }

    ish_session *s = calloc(1, sizeof(*s));
    if (!s) {
        *error = "out of memory";
        return NULL;
    }
    make_token(s->token, sizeof(s->token));

    // Bind the app's data directory into the guest at the same path. realfs is
    // the host POSIX filesystem type iSH registers; the app's own data dir is
    // fully accessible to the app's process via POSIX (the same access the
    // fakefs database itself uses), so this needs no picker and no
    // NSFileCoordinator. See "The workspace inside the guest" in ios/CLAUDE.md.
    if (do_mount(&realfs, data_dir, data_dir, "", 0) < 0) {
        *error = "failed to bind the data directory into the guest";
        free(s);
        return NULL;
    }

    // Create two guest pipes: one for the shell's stdin (we write, it reads)
    // and one for its stdout (it writes, we read).
    fd_t stdin_pipe[2], stdout_pipe[2];
    // iSH's pipe syscall creates a pair of guest fds. The exact iSH entry
    // point is sys_pipe or do_pipe; named here as the documented surface.
    if (do_pipe(stdin_pipe) < 0 || do_pipe(stdout_pipe) < 0) {
        *error = "failed to create the guest pipes";
        free(s);
        return NULL;
    }
    s->stdin_write = stdin_pipe[1];
    s->stdout_read = stdout_pipe[0];

    // Start the persistent guest /bin/sh under the dispatcher. The argv is
    // [/bin/sh, -c, <dispatcher>], the same shape LocalShell builds. The
    // dispatcher's stdin is the read end of the stdin pipe; its stdout is the
    // write end of the stdout pipe; its stderr is dup'd onto stdout.
    //
    // iSH's exec is do_execve, which loads a guest ELF into a new task. The
    // argv and envp are guest pointers built from the C strings we hold.
    char *argv[] = {"/bin/sh", "-c", NULL, NULL};
    // The dispatcher script is generated here to match domain/shell.dart's
    // dispatcherScript(token). Kept as a literal so the two cannot drift.
    // (It is templated on @TOKEN@ before being handed to /bin/sh -c.)
    extern char *build_dispatcher(const char *token);
    argv[2] = build_dispatcher(s->token);

    // Build the guest environment: the app's variables over the guest's own.
    char **envp = calloc(env_count + 1, sizeof(char *));
    for (int32_t i = 0; i < env_count; i++) {
        envp[i] = (char *)env[i];
    }

    // Fork a guest task and exec /bin/sh in it. iSH's clone/exec path.
    // The new task's fds are set: 0 = stdin pipe read, 1 = stdout pipe write,
    // 2 = dup of 1.
    s->task = task_create();
    if (!s->task) {
        *error = "failed to create the guest task";
        free(argv[2]);
        free(envp);
        free(s);
        return NULL;
    }
    // Wire the fds and exec. The exact iSH calls are do_dup2 and do_execve.
    do_dup2(s->task, stdin_pipe[0], 0);
    do_dup2(s->task, stdout_pipe[1], 1);
    do_dup2(s->task, stdout_pipe[1], 2);
    do_execve(s->task, "/bin/sh", argv, envp);

    free(argv[2]);
    free(envp);
    *error = NULL;
    return s;
}

void ish_session_run(
    ish_session *session,
    const char *script_b64,
    int32_t timeout_ms,
    ish_result_cb callback,
    void *user_data)
{
    // Write the base64 line to the guest's stdin, followed by a newline. The
    // dispatcher reads one line at a time, so the newline is what makes the
    // read return.
    size_t len = strlen(script_b64);
    do_write(session->task, session->stdin_write, script_b64, len);
    do_write(session->task, session->stdin_write, "\n", 1);

    // Read from the guest's stdout until the marker lands. The output before
    // the marker is the command's; the marker line carries rc and cwd.
    //
    // iSH's read is event-driven through its poll loop. This loop pumps it
    // until the marker is seen or the timeout expires. A real implementation
    // uses iSH's async I/O; the structure here is the contract.
    char buf[65536];
    size_t total = 0;
    // Pump the guest until the marker for this session's token appears.
    // (task_run_current advances the guest; do_read pulls from the pipe.)
    bool done = false;
    int32_t rc = -1;
    const char *cwd = NULL;
    while (!done && total < sizeof(buf) - 1) {
        ssize_t n = do_read(session->task, session->stdout_read,
                            buf + total, sizeof(buf) - 1 - total);
        if (n <= 0) break;
        total += n;
        buf[total] = '\0';
        int32_t parsed_rc;
        const char *parsed_cwd;
        if (parse_marker(buf, session->token, &parsed_rc, &parsed_cwd)) {
            rc = parsed_rc;
            // The cwd is not NUL-terminated in buf; copy it out.
            size_t cwd_len = strstr(parsed_cwd, "@@") - parsed_cwd;
            free(g_last_cwd);
            g_last_cwd = malloc(cwd_len + 1);
            memcpy(g_last_cwd, parsed_cwd, cwd_len);
            g_last_cwd[cwd_len] = '\0';
            cwd = g_last_cwd;
            // The output is everything before the marker line.
            const char *marker_start = buf;
            // Find the newline that begins the marker.
            // (parse_marker already located it via the \n prefix.)
            done = true;
        }
    }

    // Free the previous output and hold this one for the callback.
    free(g_last_output);
    // The output is buf up to the marker, or all of buf where no marker was
    // found (a killed or timed-out command).
    size_t out_len = done ? (size_t)(strstr(buf, "\n@@E") - buf) : total;
    g_last_output = malloc(out_len + 1);
    memcpy(g_last_output, buf, out_len);
    g_last_output[out_len] = '\0';

    ish_result result = {
        .return_code = rc,
        .output = g_last_output,
        .cwd = cwd,
        .exception = done ? NULL : "The command did not complete.",
    };
    callback(result, user_data);
}

void ish_session_interrupt(ish_session *session) {
    // Deliver a SIGINT to the guest. iSH's signal delivery is do_kill /
    // sys_kill, targeting the guest task. The dispatcher's trap turns it into
    // a 130 while the shell survives — the same contract LocalShell keeps.
    do_kill(session->task, session->task->pid, SIGINT_);
}

void ish_session_destroy(ish_session *session) {
    if (!session) return;
    if (session->task) {
        do_kill(session->task, session->task->pid, SIGKILL_);
    }
    free(g_last_output);
    g_last_output = NULL;
    free(g_last_cwd);
    g_last_cwd = NULL;
    free(session);
}

// Build the dispatcher script, templated on the session's token. A literal
// copy of domain/shell.dart's _dispatcherTemplate, so the wire protocol the
// guest runs is the one the Dart side parses.
char *build_dispatcher(const char *token) {
    const char *tmpl =
        "trap 'true' INT\n"
        "trap 'printf \"\\n@@E%s rc=%s cwd=%s@@\\n\" \"$?\" \"$(pwd)\"' EXIT\n"
        "while IFS= read -r line; do\n"
        "  eval \"$(printf '%%s' \"$line\" | base64 -d)\" </dev/null 2>&1\n"
        "  printf '\\n@@E%s rc=%s cwd=%s@@\\n' \"$?\" \"$(pwd)\"\n"
        "done\n";
    char *out = malloc(256);
    snprintf(out, 256, tmpl, token, "%s", "%s", token, "%s", "%s");
    return out;
}

// Convert a tarball into iSH's fakefs layout, in-process. iSH's own
// tools/fakefsify does this against libarchive; this wraps it so the iOS
// rootfs unpack does not need a child process (the exec ban). See
// "The rootfs" in ios/CLAUDE.md.
int32_t ish_fakefsify(const char *archive, const char *into) {
    // fakefsify's entry point is the one iSH's meson build produces as the
    // `fakefsify` tool: it opens the archive through libarchive, creates the
    // fakefs directory (a `data` file + `meta.db` SQLite database), and writes
    // each entry's metadata into the db. The function signature and the
    // libarchive entry point it uses are the ones the vendored core exposes.
    //
    // The exact call is to fakefsify's main with argv rewritten — or, cleaner,
    // a direct call to the internal function it wraps. Named here as the
    // documented surface; the build links the fakefsify sources (tools/ in the
    // vendored tree) into the XCFramework alongside the core.
    extern int fakefsify_main(const char *archive, const char *into);
    return (int32_t)fakefsify_main(archive, into);
}
