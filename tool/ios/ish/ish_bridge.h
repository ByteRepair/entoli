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

// iSH's own headers, vendored under tool/ios/ish/src/.
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "fs/real.h"
#include "xX_main_Xx.h"

// The handle Dart holds. Opaque from its side; a pointer to this struct.
typedef struct {
    // The iSH guest task running the persistent /bin/sh. Null once the shell
    // has died and not yet respawned.
    struct task *task;
    // The host ends of the two pipes the session's stdio is plumbed through.
    // The guest holds the other ends as its fds 0, 1 and 2; the bridge reads
    // and writes these with the host's own read(2) and write(2), which is
    // what iSH's adhoc-fd plumbing puts behind the guest fds. hangup closes
    // and -1s the read end; destroy closes only what is still open.
    int stdin_write;
    int stdout_read;
    // The token the dispatcher's markers carry, unique to the shell's life so
    // a command's output cannot forge the end of a run.
    char token[37];
} ish_session;

// The result of one command, written into the ish_result the caller
// allocates. All three strings are heap-allocated (malloc/strdup) and owned
// by the caller: Dart frees each non-null one with calloc.free after copying
// it out. Null where there is nothing to say.
typedef struct {
    int32_t return_code;
    const char *output;     // NUL-terminated, malloc'd. Caller frees.
    const char *cwd;        // NUL-terminated, malloc'd. Caller frees; null
                            // where the shell left no directory to report.
    const char *exception;  // NUL-terminated, strdup'd, or null where the
                            // command completed.
} ish_result;

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
// suffix past the project workspace.
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
    const char **error);

// Run one command in the session's persistent guest shell. The script is
// already base64-encoded — the bridge writes it as one line to the guest's
// stdin, the dispatcher decodes and evals it, and writes a marker line back.
// Blocks until the session's own marker lands. The result is written into
// *out, which the caller allocates; its strings are the caller's to free.
void ish_session_run(
    ish_session *session,
    const char *script_b64,
    int32_t timeout_ms,
    ish_result *out);

// Deliver SIGINT to the guest shell. A no-op where the shell has died, which
// is what the task pointer being null says.
void ish_session_interrupt(ish_session *session);

// The escalation for a command that ignored the interrupt: SIGKILL the guest
// and close the read end only, so a run blocked reading the guest's stdout
// returns at once ("did not complete") and the handle's own teardown stays
// destroy's. The kill comes first, or a dying guest writes into the closing
// pipe end and the interpreter dies of SIGPIPE. Non-blocking; safe from another
// thread while ish_session_run is pending on the session.
void ish_session_hangup(ish_session *session);

// Tear down: kill the guest and close the host pipe ends. The session handle
// is invalid after this.
void ish_session_destroy(ish_session *session);

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