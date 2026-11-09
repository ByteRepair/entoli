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
#include <arpa/inet.h>
#include <netdb.h>
#include <resolv.h>

#include "tools/fakefs.h"
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/signal.h"
#include "fs/path.h"
#include "fs/real.h"

// ---- internal state ----

static bool ish_booted = false;

// ---- helpers ----

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

// Write the guest's /etc/resolv.conf from the host's resolvers, the same
// configureDns iSH's own app runs (AppDelegate.m): a fresh Alpine ships no
// resolver, so name lookups fail until one is written. The host answer changes
// with the network the device is on, so it is rewritten here on every boot
// rather than once at install. Unlike the app's, a failed probe is not fatal —
// this runs inside the app as a library, so it reports and lets the guest boot
// with whatever resolv.conf the rootfs already has.
static void configure_dns(void) {
    struct __res_state res;
    if (res_ninit(&res) != EXIT_SUCCESS) {
        printk("ish: res_ninit failed; /etc/resolv.conf left as shipped\n");
        return;
    }
    char buf[4096];
    size_t used = 0;
    if (res.dnsrch[0] != NULL) {
        int n = snprintf(buf + used, sizeof(buf) - used, "search");
        if (n > 0) used += (size_t) n;
        for (int i = 0; res.dnsrch[i] != NULL && used < sizeof(buf); i++) {
            n = snprintf(buf + used, sizeof(buf) - used, " %s", res.dnsrch[i]);
            if (n < 0) break;
            used += (size_t) n;
        }
        if (used < sizeof(buf)) {
            buf[used++] = '\n';
            buf[used] = '\0';
        }
    }
    union res_sockaddr_union servers[NI_MAXSERV];
    int found = res_getservers(&res, servers, NI_MAXSERV);
    for (int i = 0; i < found && used < sizeof(buf); i++) {
        union res_sockaddr_union s = servers[i];
        if (s.sin.sin_len == 0) continue;
        char address[NI_MAXHOST];
        if (getnameinfo(
                (struct sockaddr *) &s.sin, s.sin.sin_len, address,
                sizeof(address), NULL, 0, NI_NUMERICHOST) != 0) {
            continue;
        }
        int n = snprintf(buf + used, sizeof(buf) - used, "nameserver %s\n",
                address);
        if (n < 0) break;
        used += (size_t) n;
    }
    res_ndestroy(&res);

    struct fd *fd =
            generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (IS_ERR(fd)) {
        printk("ish: could not open /etc/resolv.conf for writing\n");
        return;
    }
    fd->ops->write(fd, buf, used);
    fd_close(fd);
}

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
    configure_dns();
    ish_booted = true;
}

// Bind a host directory at a guest path, the way proot's `-b host:guest`
// does on Android. The point has to exist in the guest tree before the mount
// lands on it, so each component is made the way init.c makes /dev/pts; a
// component that is already there is fine (EEXIST), and a mount that did not
// land is not fatal — the shell still runs, from a workspace it cannot see.
// [flags] are the mount's: MS_READONLY_ for one the guest must not change.
static int bind_host_dir(const char *host_dir, const char *point, int flags) {
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
    // do_mount walks the mount list, which wants mounts_lock (kernel/fs.h).
    lock(&mounts_lock);
    int err = do_mount(&realfs, host_dir, made, "", flags);
    unlock(&mounts_lock);
    if (err < 0) {
        printk("ish: could not bind %s at %s\n", host_dir, made);
    }
    return err;
}

// Bind the app's data directory into the guest at its own absolute host
// path — the fallback spelling, so a host-shaped path still resolves even
// though the model is told the masked one. One bind per process: every
// session binds the same paths, and a second do_mount at the same point
// would shadow the first with another fd over the same directory.
static void bind_data_dir(const char *data_dir) {
    static bool bound = false;
    if (bound) return;
    bind_host_dir(data_dir, data_dir, 0);
    bound = true;
}

// Bind each of [dirs] read-only at its own host path, over the data-dir bind
// that already reaches it writable: the longer mount point wins the lookup.
// What the app keeps read-only on disk (a chat's attachments) the guest's
// root could otherwise chmod back. Once per path for the process, the way
// the data dir is: the mount table is the guest's, not a session's.
static void bind_read_only(const char **dirs, int32_t count) {
    static char **bound = NULL;
    static int32_t bound_count = 0;
    for (int32_t i = 0; i < count; i++) {
        bool already = false;
        for (int32_t j = 0; j < bound_count && !already; j++)
            already = strcmp(bound[j], dirs[i]) == 0;
        if (already) continue;
        if (bind_host_dir(dirs[i], dirs[i], MS_READONLY_) < 0) continue;
        char **grown = realloc(bound, (bound_count + 1) * sizeof(char *));
        if (grown == NULL) continue;
        bound = grown;
        bound[bound_count++] = strdup(dirs[i]);
    }
}

// Bind the project workspace at /root — the clean guest path proot gives it
// on Android, and the one the model is told. The guest has one mount table,
// so /root names one project at a time: another workspace rebinds it, which
// IshShell asks for only once no session of the bound project is running.
// The old bind is unmounted where nothing holds it; where a dying shell
// still does, the new one shadows it (do_mount puts the newest first among
// equal-length points).
static void bind_workspace(const char *workspace) {
    static char bound_home[PATH_MAX];
    if (strcmp(bound_home, workspace) == 0) return;
    if (bound_home[0] != '\0') {
        lock(&mounts_lock);
        do_umount("/root");
        unlock(&mounts_lock);
        bound_home[0] = '\0';
    }
    if (bind_host_dir(workspace, "/root", 0) == 0) {
        snprintf(bound_home, sizeof(bound_home), "%s", workspace);
    }
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
    const char **read_only,
    int32_t read_only_count,
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
        bind_read_only(read_only, read_only_count);
    }
    if (home[0] != '\0' && cwd[0] != '\0') {
        bind_workspace(home);
    }

    ish_session *s = calloc(1, sizeof(*s));
    if (!s) {
        *error = "out of memory";
        return NULL;
    }
    strncpy(s->token, token, sizeof(s->token) - 1);

    // Two real host pipes; the guest gets the other ends as fds 0, 1 and 2.
    // Beside them the wake pipe the hangup's byte lands in, whose read end is
    // non-blocking, which is what makes each run's drain of a previous
    // command's byte safe. -1 until made, since fd 0 is a real fd here and
    // the failure path closes only what was opened. Made before the guest
    // task, so a failure here has no task to leave behind.
    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};
    int wake_pipe[2] = {-1, -1};
    if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0 || pipe(wake_pipe) < 0) {
        *error = "failed to create the session pipes";
        goto fail;
    }
    int wake_flags = fcntl(wake_pipe[0], F_GETFL, 0);
    if (wake_flags >= 0) {
        fcntl(wake_pipe[0], F_SETFL, wake_flags | O_NONBLOCK);
    }

    // A child of the kernel's init task: its own mm, fds, and signal state,
    // with `current` switched to it for the calls below. This is
    // TerminalViewController's -startSession without the tty — the
    // dispatcher runs non-interactively over pipes instead.
    if (become_new_init_child() < 0) {
        *error = "failed to create the guest task";
        goto fail;
    }
    struct task *task = current;

    // A fresh init child's table is empty, so the three installs land on
    // fds 0, 1 and 2 in this order.
    fd_t in = guest_fd_from_host(stdin_pipe[0]);
    fd_t out = guest_fd_from_host(stdout_pipe[1]);
    fd_t errfd = guest_fd_from_host(stdout_pipe[1]);
    if (in != 0 || out != 1 || errfd != 2) {
        *error = "failed to wire the guest stdio";
        goto fail;
    }

    // The working directory the guest shell starts in is the chat's own, in
    // the guest's words: /root plus the chat workspace's suffix past the
    // project workspace. Dart computes it; the /root bind above is what
    // makes it resolve.
    struct fd *pwd = generic_open(cwd, O_RDONLY_, 0);
    if (IS_ERR(pwd)) {
        *error = "the working directory could not be opened in the guest";
        goto fail;
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
        goto fail;
    }
    s->pid = task->pid;
    s->stdin_write = stdin_pipe[1];
    s->stdout_read = stdout_pipe[0];
    s->wake_read = wake_pipe[0];
    s->wake_write = wake_pipe[1];
    // task_start sets the task's pthread going; do_execve only dressed it.
    task_start(task);

    *error = NULL;
    return s;

fail:
    for (int i = 0; i < 2; i++) {
        if (stdin_pipe[i] >= 0) close(stdin_pipe[i]);
        if (stdout_pipe[i] >= 0) close(stdout_pipe[i]);
        if (wake_pipe[i] >= 0) close(wake_pipe[i]);
    }
    free(s);
    return NULL;
}

void ish_session_drain_wake(ish_session *session) {
    if (!session) return;
    // Consume what a hung-up handle might owe the next command. Under the
    // session contract it is empty: hangup applies to a run still pending,
    // whose own poll takes the byte, and destroy closes the pair before any
    // command could reuse the handle. The drain is the guard a contract
    // change would want — a stale byte would end the next run before the
    // guest has spoken — and O_NONBLOCK is what keeps the drain from doing
    // so.
    char discarded;
    while (read(session->wake_read, &discarded, 1) == 1) {}
}

void ish_session_write_stdin(ish_session *session, const char *script_b64) {
    if (!session) return;
    // Write the base64 line to the guest's stdin, followed by a newline. The
    // dispatcher reads one line at a time, so the newline is what makes the
    // read return.
    size_t len = strlen(script_b64);
    ssize_t unused = write(session->stdin_write, script_b64, len);
    (void) unused;
    unused = write(session->stdin_write, "\n", 1);
    (void) unused;
}

int32_t ish_session_poll(ish_session *session) {
    if (!session) return -1;
    // Polled on both ends rather than read plainly: a child the
    // escalation's SIGKILL did not reach can hold the guest's write end for
    // its own life. The wake pipe's byte is the whole of the ending another
    // thread can deliver.
    struct pollfd fds[2];
    fds[0].fd = session->stdout_read;
    fds[0].events = POLLIN;
    fds[1].fd = session->wake_read;
    fds[1].events = POLLIN;
    for (;;) {
        int nready = poll(fds, 2, -1);
        if (nready < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        // HUP/ERR on stdout still answers the read (zero bytes, or the
        // error), so it is worth reading rather than a poll fault.
        int32_t flags =
            (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0 ? 1 : 0;
        if ((fds[1].revents & POLLIN) != 0) flags |= 2;
        return flags;
    }
}

int32_t ish_session_read(ish_session *session, char *buf, int32_t cap) {
    if (!session || cap < 0) return -1;
    ssize_t n = read(session->stdout_read, buf, (size_t) cap);
    if (n > 0) return (int32_t) n;
    if (n == 0) return 0;
    if (errno == EINTR || errno == EAGAIN) return -2;
    return -1;
}

void ish_session_interrupt(ish_session *session) {
    // Deliver a SIGINT to the guest's process group, the Ctrl-C LocalShell
    // sends its own. The dispatcher's trap turns it into a 130 while the
    // shell survives. send_group_signal looks the group up under pids_lock
    // and answers ESRCH where it is gone, so a dead session is a no-op.
    if (!session || session->pid <= 0) return;
    send_group_signal(session->pid, SIGINT_, SIGINFO_NIL);
}

void ish_session_hangup(ish_session *session) {
    if (!session) return;
    if (session->pid > 0) {
        send_group_signal(session->pid, SIGKILL_, SIGINFO_NIL);
    }
    // The byte is what the run's poll answers. stdout is not closed here:
    // the worker may be reading it, and a close from this thread could hand
    // its number to another open before that read lands.
    if (session->wake_write >= 0) {
        char wake = 0;
        ssize_t unused = write(session->wake_write, &wake, 1);
        (void) unused;
    }
}

void ish_session_destroy(ish_session *session) {
    if (!session) return;
    if (session->pid > 0) {
        send_group_signal(session->pid, SIGKILL_, SIGINFO_NIL);
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

// ---- pipe sessions (a guest program run directly) ----

// The registry of live pipe sessions the exit hook walks, one node per session.
// Guarded by pids_lock: the hook runs under it (do_exit holds it), and
// init/destroy take it around their own list edits.
static ish_pipe_session *pipe_sessions = NULL;

// The kernel's exit hook for pipe sessions. do_exit calls it under pids_lock
// when a task's whole thread group has exited, with the task and its raw status
// (status << 8 for a normal exit, the bare signal number for a signal death —
// the same encoding xX_main_Xx's exit_handler decodes). It finds the session
// whose pid matches and announces the exit: the atomics for the worker to read,
// then one byte in the wake pipe so a poll parked beside the program's stdio
// returns. Nothing here may take pids_lock again, and the write is a single
// byte into a pipe nothing else fills, so it cannot block a do_exit.
//
// The match is on tgid, not pid: the hook fires with `current` as the *last*
// thread of the group to die, and its pid is its own thread id — only the
// group leader's pid equals the tgid stored at init. A multi-threaded program
// (codex, claude — tokio, jemalloc) always exits from a non-leader thread, so
// a pid match would never fire and the exit code would read -1 forever.
static void pipe_exit_hook(struct task *task, int code) {
    for (ish_pipe_session *s = pipe_sessions; s != NULL; s = s->next) {
        if (s->pid != task->tgid) continue;
        atomic_store(&s->exited, true);
        // code & 0xff != 0 is a signal death (the bare signal number); a
        // normal exit has status in the high byte. Report the shell's shape:
        // 0-255, or 128+signal.
        int code8 = (code & 0xff) != 0 ? 128 + (code & 0xff) : (code >> 8);
        atomic_store(&s->exit_code, code8);
        if (s->wake_write >= 0) {
            char wake = 0;
            ssize_t unused = write(s->wake_write, &wake, 1);
            (void) unused;
        }
        return;
    }
}

ish_pipe_session *ish_pipe_init(
    const char *rootfs_dir,
    const char *data_dir,
    const char *home,
    const char *cwd,
    const char **argv,
    int32_t argc,
    const char **env,
    int32_t env_count,
    const char **read_only,
    int32_t read_only_count,
    const char **error)
{
    if (!ish_booted) {
        ish_boot(rootfs_dir);
        if (!ish_booted) {
            *error = "the rootfs could not be mounted; is it installed?";
            return NULL;
        }
    }
    if (data_dir[0] != '\0') {
        bind_data_dir(data_dir);
        bind_read_only(read_only, read_only_count);
    }
    if (home[0] != '\0' && cwd[0] != '\0') {
        bind_workspace(home);
    }

    ish_pipe_session *s = calloc(1, sizeof(*s));
    if (!s) {
        *error = "out of memory";
        return NULL;
    }
    s->stdin_write = -1;
    s->stdout_read = -1;
    s->stderr_read = -1;
    s->wake_read = -1;
    s->wake_write = -1;
    atomic_init(&s->exited, false);
    atomic_init(&s->exit_code, -1);

    // Three host pipes — stdin, stdout, and a separate stderr so the program's
    // diagnostics do not mix into the JSON lines the caller parses — plus the
    // wake pipe the exit's byte lands in.
    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    int wake_pipe[2] = {-1, -1};
    if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0 ||
        pipe(stderr_pipe) < 0 || pipe(wake_pipe) < 0) {
        *error = "failed to create the session pipes";
        goto fail;
    }
    int wake_flags = fcntl(wake_pipe[0], F_GETFL, 0);
    if (wake_flags >= 0) {
        fcntl(wake_pipe[0], F_SETFL, wake_flags | O_NONBLOCK);
    }

    if (become_new_init_child() < 0) {
        *error = "failed to create the guest task";
        goto fail;
    }
    struct task *task = current;

    // fds 0, 1 and 2, each to its own host pipe end.
    fd_t in = guest_fd_from_host(stdin_pipe[0]);
    fd_t out = guest_fd_from_host(stdout_pipe[1]);
    fd_t errfd = guest_fd_from_host(stderr_pipe[1]);
    if (in != 0 || out != 1 || errfd != 2) {
        *error = "failed to wire the guest stdio";
        goto fail;
    }

    struct fd *pwd = generic_open(cwd, O_RDONLY_, 0);
    if (IS_ERR(pwd)) {
        *error = "the working directory could not be opened in the guest";
        goto fail;
    }
    fs_chdir(task->fs, pwd);

    // The program runs under `exec "$@"`, so a bare name resolves through the
    // guest's PATH and the arguments reach it unsplit; the exec replaces the
    // shell, so the pid the signals go through is the program's own.
    const char *parts[] = {"/bin/sh", "-c", "exec \"$@\"", "sh", NULL};
    char argv_flat[4096];
    size_t pos = 0;
    size_t nparts = 0;
    for (size_t i = 0; parts[i] != NULL; i++) {
        size_t len = strlen(parts[i]) + 1;
        if (pos + len > sizeof(argv_flat)) break;
        memcpy(&argv_flat[pos], parts[i], len);
        pos += len;
        nparts++;
    }
    for (int32_t i = 0; i < argc; i++) {
        size_t len = strlen(argv[i]) + 1;
        if (pos + len > sizeof(argv_flat)) break;
        memcpy(&argv_flat[pos], argv[i], len);
        pos += len;
        nparts++;
    }
    argv_flat[pos] = '\0';

    char envp[8192];
    pos = 0;
    for (int32_t i = 0; i < env_count; i++) {
        size_t len = strlen(env[i]) + 1;
        if (pos + len > sizeof(envp) - 1) break;
        memcpy(&envp[pos], env[i], len);
        pos += len;
    }
    envp[pos] = '\0';

    if (do_execve("/bin/sh", nparts, argv_flat, envp) < 0) {
        *error = "failed to exec the program in the guest";
        goto fail;
    }

    s->pid = task->pid;
    s->stdin_write = stdin_pipe[1];
    s->stdout_read = stdout_pipe[0];
    s->stderr_read = stderr_pipe[0];
    s->wake_read = wake_pipe[0];
    s->wake_write = wake_pipe[1];

    // Register before the task starts, so an exit that races the first poll is
    // still announced. The hook runs under pids_lock; take it here too.
    lock(&pids_lock);
    exit_hook = pipe_exit_hook;
    s->next = pipe_sessions;
    pipe_sessions = s;
    unlock(&pids_lock);

    task_start(task);

    *error = NULL;
    return s;

fail:
    for (int i = 0; i < 2; i++) {
        if (stdin_pipe[i] >= 0) close(stdin_pipe[i]);
        if (stdout_pipe[i] >= 0) close(stdout_pipe[i]);
        if (stderr_pipe[i] >= 0) close(stderr_pipe[i]);
        if (wake_pipe[i] >= 0) close(wake_pipe[i]);
    }
    free(s);
    return NULL;
}

void ish_pipe_write(ish_pipe_session *session, const char *buf, int32_t len) {
    if (!session || len <= 0 || session->stdin_write < 0) return;
    ssize_t unused = write(session->stdin_write, buf, (size_t) len);
    (void) unused;
}

void ish_pipe_close_input(ish_pipe_session *session) {
    if (!session || session->stdin_write < 0) return;
    close(session->stdin_write);
    session->stdin_write = -1;
}

int32_t ish_pipe_poll(ish_pipe_session *session) {
    if (!session) return -1;
    struct pollfd fds[3];
    fds[0].fd = session->stdout_read;
    fds[0].events = POLLIN;
    fds[1].fd = session->stderr_read;
    fds[1].events = POLLIN;
    fds[2].fd = session->wake_read;
    fds[2].events = POLLIN;
    for (;;) {
        int nready = poll(fds, 3, -1);
        if (nready < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        // The wake byte is the single authoritative end signal: do_exit closes
        // the process's fds before it runs the exit hook, so a stream's EOF is
        // always visible before the exit code the hook stores. Reading that EOF
        // as the end races ahead of the code and reports -1. So a stream at EOF
        // is dropped from the poll (fd set to -1, which poll ignores) and the
        // wait goes on for the wake pipe alone.
        if ((fds[2].revents & (POLLIN | POLLHUP | POLLERR)) != 0) return 4;
        int32_t flags = 0;
        if (fds[0].fd >= 0) {
            if ((fds[0].revents & POLLIN) != 0) {
                flags |= 1;
            } else if ((fds[0].revents & (POLLHUP | POLLERR)) != 0) {
                fds[0].fd = -1;
            }
        }
        if (fds[1].fd >= 0) {
            if ((fds[1].revents & POLLIN) != 0) {
                flags |= 2;
            } else if ((fds[1].revents & (POLLHUP | POLLERR)) != 0) {
                fds[1].fd = -1;
            }
        }
        if (flags != 0) return flags;
    }
}

int32_t ish_pipe_read(
    ish_pipe_session *session, int32_t stream, char *buf, int32_t cap) {
    if (!session || cap < 0) return -1;
    int fd = stream == 0 ? session->stdout_read : session->stderr_read;
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, (size_t) cap);
    if (n > 0) return (int32_t) n;
    if (n == 0) return 0;
    if (errno == EINTR || errno == EAGAIN) return -2;
    return -1;
}

void ish_pipe_terminate(ish_pipe_session *session) {
    if (!session || session->pid <= 0) return;
    send_group_signal(session->pid, SIGTERM_, SIGINFO_NIL);
}

void ish_pipe_hangup(ish_pipe_session *session) {
    if (!session) return;
    if (session->pid > 0) {
        send_group_signal(session->pid, SIGKILL_, SIGINFO_NIL);
    }
    if (session->wake_write >= 0) {
        char wake = 0;
        ssize_t unused = write(session->wake_write, &wake, 1);
        (void) unused;
    }
}

void ish_pipe_destroy(ish_pipe_session *session) {
    if (!session) return;
    if (session->pid > 0) {
        send_group_signal(session->pid, SIGKILL_, SIGINFO_NIL);
    }
    if (session->stdin_write >= 0) close(session->stdin_write);
    if (session->stdout_read >= 0) close(session->stdout_read);
    if (session->stderr_read >= 0) close(session->stderr_read);
    if (session->wake_read >= 0) close(session->wake_read);
    if (session->wake_write >= 0) close(session->wake_write);
    // Unlink from the registry.
    lock(&pids_lock);
    ish_pipe_session **link = &pipe_sessions;
    while (*link != NULL && *link != session) link = &(*link)->next;
    if (*link == session) *link = session->next;
    unlock(&pids_lock);
    free(session);
}

int32_t ish_pipe_exit_code(ish_pipe_session *session) {
    if (!session) return -1;
    return atomic_load(&session->exited) ? atomic_load(&session->exit_code) : -1;
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