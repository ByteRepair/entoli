// ish_bridge.c — the FFI adapter over the iSH emulator core.
//
// iOS denies an app a child process, so the shell every other platform has —
// one that does Process.start of /bin/sh or a bundled proot — cannot work here.
// iSH runs the whole guest in-process, and this is the thin C surface Dart
// drives it through. See ios/AGENTS.md for the constraints that shape it.
//
// The session lifecycle mirrors LocalShell's _Session: a persistent guest
// /bin/sh fed one base64 line at a time, whose output carries a marker naming
// the exit code and the directory the shell is now in. The dispatcher script
// (domain/shell.dart's dispatcherScript) runs inside the guest's own /bin/sh,
// so a cd or an export in one emulated command sticks for the next — the same
// contract the host shell keeps.
//
// The stdio plumbing is iSH's own adhoc-fd trick: a real host pipe wrapped
// into a guest fd the way sys_pipe wraps one (fs/pipe.c's pipe_f_create) and
// the way the CLI wires its own stdio (kernel/init.c's open_fd_from_actual_fd).
// The guest reads fd 0 and writes fd 1; the bridge reads and writes the host
// ends with plain read(2) and write(2).

#include "ish_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sys/stat.h>

#include "tools/fakefs.h"
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "fs/path.h"
#include "fs/real.h"

// ---- internal state ----

static bool ish_booted = false;

// ---- helpers ----

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

// The output of a run, allocated for the caller: Dart frees it.
static char *dup_range(const char *buf, size_t len) {
    char *copy = malloc(len + 1);
    if (!copy) return NULL;
    memcpy(copy, buf, len);
    copy[len] = '\0';
    return copy;
}

// A host fd as a guest fd on the current task: the same three lines
// open_fd_from_actual_fd (kernel/init.c) runs, over the realfs fd ops — the
// guest reads and writes it through the host file it names. The fd lands in
// the table's first free slot; on a fresh init child the three calls below
// fill slots 0, 1 and 2.
static fd_t guest_fd_from_host(int real_fd) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd == NULL) return (fd_t) -1;
    fd->real_fd = real_fd;
    fd->dir = NULL;
    return f_install(fd, 0);
}

// ---- lifecycle ----

void ish_boot(const char *rootfs_dir) {
    if (ish_booted) return;
    // The subset of xX_main_Xx + the app's own boot (AppDelegate -boot) that
    // a guest needs before a shell can run, minus the exec: the fakefs root
    // at "/", the first process for the device-node work to hang off, the
    // static device nodes, and /proc + /dev/pts. A failed mount leaves
    // ish_booted false, so the next init retries rather than running a
    // guest with no root.
    //
    // The fakefs is mounted from the rootfs's `data` subdirectory, the way
    // the app's own boot mounts `<root>/data`: fakefs_mount asserts the
    // source ends in "data" and derives the sibling meta.db from it. What
    // callers hand this bridge is the rootfs directory itself.
    char data_dir[PATH_MAX];
    snprintf(data_dir, sizeof(data_dir), "%s/data", rootfs_dir);
    if (mount_root(&fakefs, data_dir) < 0) {
        return;
    }
    if (become_first_process() < 0) {
        return;
    }
    create_some_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    ish_booted = true;
}

// Bind a host directory at a guest path, the way proot's `-b host:guest`
// does on Android. The point has to exist in the guest tree before the mount
// lands on it, so each component is made the way init.c makes /dev/pts; a
// component that is already there is fine (EEXIST), and a mount that did not
// land is not fatal — the shell still runs, from a workspace it cannot see.
static void bind_host_dir(const char *host_dir, const char *point) {
    char made[PATH_MAX];
    snprintf(made, sizeof(made), "%s", point);
    // mkdir -p, in the guest, one component at a time: do_mount wants the
    // point to exist. These land in the fakefs, and the mount then shadows
    // them — the fakefs copies stay empty forever.
    for (char *p = made + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        generic_mkdirat(AT_PWD, made, 0777);
        *p = '/';
    }
    generic_mkdirat(AT_PWD, made, 0777);
    if (do_mount(&realfs, host_dir, made, "", 0) < 0) {
        printk("ish: could not bind %s at %s\n", host_dir, made);
        return;
    }
}

// Bind the app's data directory into the guest at its own absolute host
// path — the fallback spelling, so a host-shaped path still resolves even
// though the model is told the masked one. One bind per process: every
// session binds the same paths, and a second do_mount at the same point
// would shadow the first with another fd over the same directory.
static void bind_data_dir(const char *data_dir) {
    static bool bound = false;
    if (bound) return;
    bind_host_dir(data_dir, data_dir);
    bound = true;
}

// Bind the project workspace at /root — the clean guest path proot gives it
// on Android, and the one the model is told. One bind per process, like the
// data-dir one.
static void bind_workspace(const char *workspace) {
    static bool bound = false;
    if (bound) return;
    bind_host_dir(workspace, "/root");
    bound = true;
}

ish_session *ish_session_init(
    const char *rootfs_dir,
    const char *data_dir,
    const char *home,
    const char *cwd,
    const char *dispatcher,
    const char *token,
    const char **env,
    int32_t env_count,
    const char **error)
{
    // [home] is bound at /root by bind_workspace below, and [cwd] is where
    // the shell starts in the guest's own words. The data-dir bind stays as
    // the fallback spelling. See "The workspace inside the guest" in
    // ios/AGENTS.md.
    if (!ish_booted) {
        ish_boot(rootfs_dir);
        if (!ish_booted) {
            *error = "the rootfs could not be mounted; is it installed?";
            return NULL;
        }
    }
    if (data_dir[0] != '\0') {
        bind_data_dir(data_dir);
    }
    if (home[0] != '\0' && cwd[0] != '\0') {
        bind_workspace(home);
    }

    // A child of the kernel's init task: its own mm, fds, and signal state,
    // with `current` switched to it for the calls below. This is
    // TerminalViewController's -startSession without the tty — the
    // dispatcher runs non-interactively over pipes instead.
    if (become_new_init_child() < 0) {
        *error = "failed to create the guest task";
        return NULL;
    }
    struct task *task = current;

    ish_session *s = calloc(1, sizeof(*s));
    if (!s) {
        *error = "out of memory";
        return NULL;
    }
    // -1, not calloc's zero: fd 0 is a real fd here, and destroy closes only
    // what is still open.
    s->stdin_write = -1;
    s->stdout_read = -1;
    s->wake_read = -1;
    s->wake_write = -1;
    strncpy(s->token, token, sizeof(s->token) - 1);

    // Two real host pipes; the guest gets the other ends as fds 0, 1 and 2.
    int stdin_pipe[2], stdout_pipe[2];
    if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0) {
        *error = "failed to create the session pipes";
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        free(s);
        return NULL;
    }
    s->stdin_write = stdin_pipe[1];
    s->stdout_read = stdout_pipe[0];
    // The wake pipe the hangup's byte lands in. Its read end is non-blocking,
    // which is what makes each run's drain of a previous command's byte safe.
    int wake_pipe[2];
    if (pipe(wake_pipe) < 0) {
        *error = "failed to create the session pipes";
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        free(s);
        return NULL;
    }
    s->wake_read = wake_pipe[0];
    s->wake_write = wake_pipe[1];
    int wake_flags = fcntl(s->wake_read, F_GETFL, 0);
    if (wake_flags >= 0) {
        fcntl(s->wake_read, F_SETFL, wake_flags | O_NONBLOCK);
    }
    // A fresh init child's table is empty, so the three installs land on
    // fds 0, 1 and 2 in this order.
    fd_t in = guest_fd_from_host(stdin_pipe[0]);
    fd_t out = guest_fd_from_host(stdout_pipe[1]);
    fd_t errfd = guest_fd_from_host(stdout_pipe[1]);
    if (in != 0 || out != 1 || errfd != 2) {
        *error = "failed to wire the guest stdio";
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(s->wake_read);
        close(s->wake_write);
        free(s);
        return NULL;
    }

    // The working directory the guest shell starts in is the chat's own, in
    // the guest's words: /root plus the chat workspace's suffix past the
    // project workspace. Dart computes it; the /root bind above is what
    // makes it resolve.
    struct fd *pwd = generic_open(cwd, O_RDONLY_, 0);
    if (IS_ERR(pwd)) {
        *error = "the working directory could not be opened in the guest";
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(s->wake_read);
        close(s->wake_write);
        free(s);
        return NULL;
    }
    fs_chdir(task->fs, pwd);

    // Start the persistent guest /bin/sh under the dispatcher. argv and envp
    // are flat NUL-joined strings — do_execve's shape (kernel/exec.c), the
    // same one xX_main_Xx builds. argv[0] is the program name itself:
    // /bin/sh is busybox, which picks its applet off argv[0], and an argv
    // that starts at "-c" reads as an applet named "-c" ("c: applet not
    // found").
    char argv[4096];
    size_t pos = 0;
    const char *parts[] = {"/bin/sh", "-c", dispatcher};
    for (size_t i = 0; i < 3 && pos < sizeof(argv) - 1; i++) {
        size_t len = strlen(parts[i]) + 1;
        if (pos + len > sizeof(argv)) break;
        memcpy(&argv[pos], parts[i], len);
        pos += len;
    }
    argv[pos] = '\0';
    char envp[8192];
    pos = 0;
    for (int32_t i = 0; i < env_count; i++) {
        size_t len = strlen(env[i]) + 1;
        if (pos + len > sizeof(envp) - 1) break;
        memcpy(&envp[pos], env[i], len);
        pos += len;
    }
    envp[pos] = '\0';
    if (do_execve("/bin/sh", 3, argv, envp) < 0) {
        *error = "failed to exec /bin/sh in the guest; the rootfs has none";
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(s->wake_read);
        close(s->wake_write);
        free(s);
        return NULL;
    }
    // task_start sets the task's pthread going; do_execve only dressed it.
    task_start(task);

    *error = NULL;
    return s;
}

void ish_session_run(
    ish_session *session,
    const char *script_b64,
    int32_t timeout_ms,
    ish_result *out)
{
    (void) timeout_ms;  // the poll blocks on the guest; escalation is Dart's
                        // destroy — see the isolate's contract in
                        // ish_shell.dart.
    // Consume what a hung-up handle might owe the next command. Under the
    // session contract it is empty: hangup applies to a run still pending,
    // whose own poll takes the byte, and destroy closes the pair before any
    // command could reuse the handle. The drain is the guard a contract
    // change would want — a stale byte would end its run before the guest
    // has spoken — and O_NONBLOCK is what keeps the drain from doing so.
    char discarded;
    while (read(session->wake_read, &discarded, 1) == 1) {}

    // Write the base64 line to the guest's stdin, followed by a newline. The
    // dispatcher reads one line at a time, so the newline is what makes the
    // read return.
    size_t len = strlen(script_b64);
    ssize_t unused = write(session->stdin_write, script_b64, len);
    (void) unused;
    unused = write(session->stdin_write, "\n", 1);
    (void) unused;

    // Read from the guest's stdout until this command's own marker lands.
    // The token in the prefix is what says it is ours: the marker of a
    // previous command left unread in the pipe — a capped or interrupted run
    // leaves one — carries the same session token, and reading it back would
    // report the previous command's exit code for this one. A stale marker is
    // dropped with the line it ends on; the output before it is kept.
    //
    // Polled on both ends rather than read plainly: a close of stdout_read
    // does not wake a reader parked on the same fd, and a child the
    // escalation's SIGKILL did not reach can hold the guest's write end for
    // its own life. The wake pipe's byte is the whole of the ending another
    // thread can deliver: once hangup has -1'd stdout, poll passes that
    // entry over (fd < 0 answers nothing), and the read that races the
    // close still EBADFs out the same way.
    char buf[65536];
    size_t total = 0;
    bool done = false;
    bool stale = false;
    int32_t rc = -1;
    char *cwd = NULL;
    while (!done && total < sizeof(buf) - 1) {
        struct pollfd fds[2];
        fds[0].fd = session->stdout_read;
        fds[0].events = POLLIN;
        fds[1].fd = session->wake_read;
        fds[1].events = POLLIN;
        int nready = poll(fds, 2, -1);
        if (nready < 0) {
            if (errno == EINTR) continue;
            break;  // "did not complete"
        }
        if (fds[1].revents & POLLIN) break;  // the hangup's byte.
        ssize_t n = read(session->stdout_read, buf + total,
                         sizeof(buf) - 1 - total);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) break;  // EOF: the guest shell is gone.
        total += (size_t) n;
        buf[total] = '\0';
        int32_t parsed_rc;
        const char *parsed_cwd;
        if (parse_marker(buf, session->token, &parsed_rc, &parsed_cwd)) {
            rc = parsed_rc;
            size_t cwd_len = strstr(parsed_cwd, "@@") - parsed_cwd;
            cwd = malloc(cwd_len + 1);
            if (cwd) {
                memcpy(cwd, parsed_cwd, cwd_len);
                cwd[cwd_len] = '\0';
            }
            done = true;
        } else if (strstr(buf, "\n@@E") != NULL) {
            // A marker line that is not ours: drop everything before the end
            // of it, so the search does not find the same stale text again.
            char *after = strstr(buf, "\n@@E");
            const char *nl = strchr(after + 1, '\n');
            size_t consumed = nl ? (size_t)(nl - buf + 1) : total;
            memmove(buf, buf + consumed, total - consumed);
            total -= consumed;
            buf[total] = '\0';
            stale = true;
        }
    }

    // The command's output is everything before the first marker line, ours
    // or a stale one's — the marker itself is not this command's words.
    const char *cut = strstr(buf, "\n@@E");
    size_t out_len = done || stale || cut
        ? (size_t)(cut - buf)
        : total;
    if (!done) rc = -1;
    char *output = dup_range(buf, out_len);

    *out = (ish_result){
        .return_code = rc,
        .output = output,
        .cwd = cwd,
        .exception = done ? NULL : strdup("The command did not complete."),
    };
}

void ish_session_interrupt(ish_session *session) {
    // Deliver a SIGINT to the guest. The dispatcher's trap turns it into a
    // 130 while the shell survives — the same contract LocalShell keeps.
    // Null after the shell died: interrupting a dead session is a no-op, the
    // way kill() on a dead process is.
    if (!session || !session->task) return;
    send_signal(session->task, SIGINT_, SIGINFO_NIL);
}

void ish_session_hangup(ish_session *session) {
    if (!session) return;
    if (session->task) {
        send_signal(session->task, SIGKILL_, SIGINFO_NIL);
    }
    if (session->stdout_read >= 0) {
        close(session->stdout_read);
        session->stdout_read = -1;
    }
    // The byte, not the close, is what the run's poll answers: the byte can
    // be sent from this thread, the close cannot wake anything.
    if (session->wake_write >= 0) {
        char wake = 0;
        ssize_t unused = write(session->wake_write, &wake, 1);
        (void) unused;
    }
    // The session stays valid — stdin, the wake pipe and the struct itself
    // stay destroy's work, which owns every close after this. The run ends
    // "did not complete" the moment its poll answers.
}

void ish_session_destroy(ish_session *session) {
    if (!session) return;
    if (session->task) {
        send_signal(session->task, SIGKILL_, SIGINFO_NIL);
    }
    if (session->stdin_write >= 0) {
        close(session->stdin_write);
    }
    if (session->stdout_read >= 0) {
        close(session->stdout_read);
    }
    if (session->wake_read >= 0) {
        close(session->wake_read);
    }
    if (session->wake_write >= 0) {
        close(session->wake_write);
    }
    free(session);
}

// Convert a tarball into iSH's fakefs layout, in-process. iSH's own
// tools/fakefsify does this against libarchive; this wraps the same
// fakefs_import it calls, so the iOS rootfs unpack does not need a child
// process (the exec ban). See "The rootfs" in ios/AGENTS.md.
//
// fakefs_import begins with mkdir(into), which fails with EEXIST where the
// directory is already there — and the Dart store always has it there, having
// created it to receive the download, which it writes *into* the directory it
// will name as the target. iSH's CLI avoids all of this by rmdir'ing its
// target first. So: move the archive out of the target (the store's layout
// has nothing else in it), rmdir what is left, and import from the archive's
// new place. A target holding something other than the archive — the dir is
// not empty after the move — is a real error, left for the caller to see
// rather than something to overwrite.
int32_t ish_fakefsify(const char *archive, const char *into) {
    struct fakefsify_error err = {0};
    // The archive moves beside the target, not inside it — it is the target's
    // own directory that has to be emptied to be rmdir'd.
    char aside[PATH_MAX];
    snprintf(aside, sizeof(aside), "%s.importing", into);
    char original[PATH_MAX];
    snprintf(original, sizeof(original), "%s", archive);
    int moved = 0;
    if (rename(archive, aside) == 0) {
        moved = 1;
        archive = aside;
    }
    if (rmdir(into) < 0 && errno != ENOENT) {
        if (moved) {
            // put it back where the caller left it, so a retry sees the
            // layout it wrote
            rename(aside, original);
        }
        return -(errno > 0 ? errno : EIO);
    }
    bool ok = fakefs_import(archive, into, &err, (struct progress) {});
    if (moved) {
        // Either way the tarball goes back where the caller left it: on
        // failure so a retry does not re-download, on success because the
        // store deletes the archive itself and counts on finding it there.
        rename(aside, original);
    }
    if (ok) {
        return 0;
    }
    return err.type == ERR_SQLITE ? -1
         : err.type == ERR_POSIX  ? -(err.code > 0 ? err.code : EIO)
                                  : -EIO;
}