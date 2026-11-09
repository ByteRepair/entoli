// ish_bridge.h — the FFI adapter over the iSH emulator core.
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
// Built by tool/ios/ish/build.sh alongside the iSH core, and linked into
// the same XCFramework. The Dart side is lib/data/local/ish_ffi.dart.
#ifndef ISH_BRIDGE_H
#define ISH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>

// iSH's own headers, vendored under tool/ios/ish/src/.
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "fs/real.h"
#include "xX_main_Xx.h"

// The handle Dart holds. Opaque from its side; a pointer to this struct.
typedef struct {
    // The guest pid of the persistent /bin/sh, which is also its process
    // group: every init child is its own session leader (construct_task's
    // task_setsid), and the commands it runs inherit the group. A pid rather
    // than the task, which is freed when the shell exits; the signals go
    // through send_group_signal, which looks it up under pids_lock.
    pid_t_ pid;
    // The host ends of the two pipes the session's stdio is plumbed through.
    // The guest holds the other ends as its fds 0, 1 and 2; the bridge reads
    // and writes these with the host's own read(2) and write(2), which is
    // what iSH's adhoc-fd plumbing puts behind the guest fds. destroy closes
    // every one; nothing else does, so a worker's read never races a reused
    // fd number.
    int stdin_write;
    int stdout_read;
    // A pipe the hangup's byte lands in, whose read end a run polls beside
    // stdout. A close does not wake a reader parked on the same fd, and a
    // child the hangup's SIGKILL did not reach can hold the guest's write
    // end for its own life — the byte is what ends the run from another
    // thread. Each run drains the pipe before waiting, the guard a reused
    // hung-up handle would want; the read end is O_NONBLOCK, which is what
    // keeps that drain from holding the run.
    int wake_read;
    int wake_write;
    // The token the dispatcher's markers carry, unique to the shell's life so
    // a command's output cannot forge the end of a run.
    char token[37];
} ish_session;

// ---- lifecycle ----

// Boot iSH's kernel once. Idempotent: the second call is a no-op. Called from
// the background isolate before any session is made, so the kernel's
// singletons (the mount list, the process table) exist. The subset of
// xX_main_Xx the app's own boot does: the root filesystem mounted at "/",
// the first process, the device nodes, and /proc + /dev/pts. No exec here —
// pid 1 stays an empty task and every session is one of its children.
// A failed mount leaves the kernel unbooted, so the next init retries it.
void ish_boot(const char *rootfs_dir);

// Make a session: fork a child of the kernel's init task, wire its stdio to
// two host pipes the bridge reads and writes, start a persistent /bin/sh
// under the dispatcher. [home] is the host project workspace, bound into the
// guest at /root (the same clean path proot gives it on Android, so the
// model is told `~` and not the app container's layout); [cwd] is where the
// shell starts, in the guest's own words — /root plus the chat workspace's
// suffix past the project workspace. /root names one project at a time: a
// [home] other than the bound one rebinds it, which the caller does only
// once no session of the other project is left running. [read_only] are host
// directories bound read-only at their own paths (iSH patched to refuse a
// write through a read-only mount), kept for the life of the process.
//
// Returns null and sets *error where the rootfs is not present or the shell
// failed to start.
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
    const char **error);

// Begin a command: first drain the wake pipe, then write the base64 command
// line to the guest's stdin followed by a newline — the dispatcher reads one
// line at a time, so the newline is what makes the read return. Under the
// session contract the drain finds nothing: hangup applies to a run still
// pending, whose own poll takes the byte, and destroy closes the pair before
// any command could reuse the handle — the drain is the guard a contract
// change would want, and is a no-op today.
void ish_session_drain_wake(ish_session *session);
void ish_session_write_stdin(ish_session *session, const char *script_b64);

// Block on the session's stdout read end and its wake pipe — this is what the
// worker parks in between a command's output chunks — and answer what woke
// it: 1 the stdout end has bytes to read (or the guest is gone; the read
// tells which), 2 the wake byte, 3 both. EINTR is waited out; a fatal poll
// error answers -1. The byte is what returns a hung-up run promptly, since a
// close does not wake a reader parked on the same fd.
int32_t ish_session_poll(ish_session *session);

// Read from the session's stdout read end into [buf]: >0 bytes read, 0 the
// guest is gone, -2 worth retrying (EINTR/EAGAIN), -1 fatal.
int32_t ish_session_read(ish_session *session, char *buf, int32_t cap);

// Deliver SIGINT to the guest shell's process group — the command and the
// shell, whose trap keeps it alive. A no-op where the group is gone.
void ish_session_interrupt(ish_session *session);

// The escalation for a command that ignored the interrupt: SIGKILL the
// guest's process group and drop one byte into the wake pipe a run polls
// beside its stdout — the byte is what returns it, since a child that left
// the group can hold the guest's write end for its own life. The read end
// stays open for destroy: closing it here would race the worker's read of
// the same fd number. Non-blocking; safe from another thread while a run is
// pending on the session.
void ish_session_hangup(ish_session *session);

// Tear down: kill the guest and close every host pipe end the session still
// holds. The session handle is invalid after this.
void ish_session_destroy(ish_session *session);

// A pipe session runs one guest program directly — not the persistent shell
// under the dispatcher — with its own stderr pipe beside stdout and stdin fed
// raw from the host. This is the transport a CLI provider (claude, codex)
// needs: JSON lines written to stdin, JSON lines read from stdout, diagnostics
// on a separate stderr, and a real exit code when the process ends. See "The
// CLI providers inside the guest" in lib/data/builtin/llm/AGENTS.md.
typedef struct ish_pipe_session {
    // The guest pid of the program, its process group (an init child is its
    // own session leader), which signals go through.
    pid_t_ pid;
    // The host ends of the three pipes the process's stdio is plumbed through.
    int stdin_write;
    int stdout_read;
    int stderr_read;
    // The wake pipe the exit (or a hangup) is announced on; the read end is
    // O_NONBLOCK, as the dispatcher session's is.
    int wake_read;
    int wake_write;
    // Set by the kernel's exit hook when the process exits, read by the worker
    // after the wake byte. The hook runs on the guest's own thread, so these
    // are atomics rather than plain ints.
    _Atomic bool exited;
    _Atomic int exit_code;
    // The registry the exit hook walks, guarded by pids_lock (which do_exit
    // holds when it calls the hook). Not read by Dart.
    struct ish_pipe_session *next;
} ish_pipe_session;

// Spawn [argv] (argv[0] the program, an absolute guest path) as a guest
// process, with [env] its environment. [home]/[cwd]/[read_only] are bound
// exactly as for the dispatcher session. Returns null and sets *error where the
// rootfs is not present or the program failed to exec.
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
    const char **error);

// Write [len] raw bytes to the process's stdin (not base64, not newline
// terminated — the caller owns the framing).
void ish_pipe_write(ish_pipe_session *session, const char *buf, int32_t len);

// Close the process's stdin, which a program reading it takes as EOF.
void ish_pipe_close_input(ish_pipe_session *session);

// Block on the process's stdout, stderr and wake pipe; answer what woke it:
// 1 stdout has bytes (or is gone), 2 stderr has bytes (or is gone), 4 the wake
// byte. EINTR is waited out; a fatal poll error answers -1.
int32_t ish_pipe_poll(ish_pipe_session *session);

// Read from [stream] (0 stdout, 1 stderr) into [buf]: >0 bytes read, 0 the
// process is gone, -2 worth retrying, -1 fatal.
int32_t ish_pipe_read(
    ish_pipe_session *session, int32_t stream, char *buf, int32_t cap);

// Deliver SIGTERM to the process's group — the graceful stop, giving the
// program a chance to clean up before the escalation below.
void ish_pipe_terminate(ish_pipe_session *session);

// The escalation: SIGKILL the group and drop the wake byte, so a run parked in
// [ish_pipe_poll] returns at once.
void ish_pipe_hangup(ish_pipe_session *session);

// Tear down: kill the guest and close every host pipe end. Invalid after this.
void ish_pipe_destroy(ish_pipe_session *session);

// The process's exit code as a shell reports one (0-255, or 128+signal), valid
// once the wake byte has announced the exit; -1 before then.
int32_t ish_pipe_exit_code(ish_pipe_session *session);

// Convert a tarball into iSH's fakefs layout, in-process. The iOS analog of
// `tar -xzf` — iOS denies an app a child process, so the system `tar` cannot
// be exec'd, and the rootfs must be unpacked into the fakefs SQLite database
// iSH's fs/fake.c models rather than into a plain directory. iSH's own
// tools/fakefsify does this against libarchive; this entry point wraps it.
//
// Returns 0 on success, non-zero on failure (which FileRootfsStore reports as
// a failed download rather than a half-unpacked rootfs).
int32_t ish_fakefsify(const char *archive, const char *into);

#endif // ISH_BRIDGE_H