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
// Built by tool/bundle/ish/build.sh alongside the iSH core, and linked into
// the same XCFramework. The Dart side is lib/data/local/ish_ffi.dart.

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// iSH's own headers, vendored under tool/bundle/ish/src/.
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/mount.h"
#include "xX_main_Xx.h"

// The handle Dart holds. Opaque from its side; a pointer to this struct.
typedef struct {
    // The iSH guest task running the persistent /bin/sh. Null once the shell
    // has died and not yet respawned.
    struct task *task;
    // The read end of the guest's stdout pipe. iSH's fs/pipe.c models the
    // pipe; the bridge reads output out of this fd.
    fd_t stdout_read;
    // The write end of the guest's stdin pipe. The bridge writes base64 lines
    // into this.
    fd_t stdin_write;
    // The token the dispatcher's markers carry, unique to the shell's life so
    // a command's output cannot forge the end of a run.
    char token[37];
} ish_session;

// The result of one command, posted back to Dart through the output callback.
typedef struct {
    int32_t return_code;
    const char *output;     // NUL-terminated. Owned by the bridge, freed on the
                            // next call or on session destroy.
    const char *cwd;        // NUL-terminated. Same lifetime as output.
    const char *exception;  // NUL-terminated, or null where there was none.
} ish_result;

// Dart passes a callback that receives the result struct. The bridge calls it
// once ish_session_run's guest execution returns.
typedef void (*ish_result_cb)(ish_result result, void *user_data);

// The environment as Dart sends it: a flat array of "KEY=VALUE" C strings,
// NUL-terminated, with a count. iSH's guest gets these as its initial
// environment below the dispatcher's own.

// ---- lifecycle ----

// Boot iSH's kernel once. Idempotent: the second call is a no-op. Called from
// the background isolate before any session is made, so the kernel's singletons
// (the mount list, the process table) exist.
//
// iSH's main.c does this through xX_main_Xx, which is written to run one
// command and exit. We need the *kernel* up but not that command, so this is
// the subset: become the first process, mount the rootfs, and return. The
// guest's /bin/sh is started per-session in ish_session_init.
static bool ish_booted = false;

void ish_boot(const char *rootfs_dir) {
    if (ish_booted) return;
    // iSH's first-process setup: the process table, signals, the vdso.
    // xX_main_Xx does this internally; the subset here is what it does before
    // it execs the guest, stopped before the exec.
    become_first_process();
    // The root filesystem is the SQLite-backed fakefs iSH models in-process.
    // mount_root sets it at "/".
    do_mount(&fakefs, rootfs_dir, "/", "", 0);
    ish_booted = true;
}

// Make a session: bind the app's data directory into the guest at the same path
// (the proot -b $dataDir:$dataDir analog — see "The workspace inside the guest"
// in ios/CLAUDE.md), start a persistent /bin/sh under the dispatcher, and wire
// its stdin/stdout to pipes the bridge reads and writes.
//
// Returns null and sets *error where the rootfs is not present or the shell
// failed to start.
ish_session *ish_session_init(
    const char *rootfs_dir,
    const char *data_dir,
    const char *home,
    const char **env,
    int32_t env_count,
    const char **error);

// Run one command in the session's persistent guest shell. The script is
// already base64-encoded — the bridge writes it as one line to the guest's
// stdin, the dispatcher decodes and evals it, and writes a marker line back.
// Blocks until the marker lands or the timeout expires.
//
// interrupt is called from Dart's kill(): it delivers a SIGINT to the guest,
// which the dispatcher's trap turns into a 130 while the shell survives.
void ish_session_run(
    ish_session *session,
    const char *script_b64,
    int32_t timeout_ms,
    ish_result_cb callback,
    void *user_data);

void ish_session_interrupt(ish_session *session);

// Tear down: kill the guest, close the pipes. The session handle is invalid
// after this.
void ish_session_destroy(ish_session *session);

// Convert a tarball into iSH's fakefs layout, in-process. The iOS analog of
// `tar -xzf` — iOS denies an app a child process, so the system `tar` cannot
// be exec'd, and the rootfs must be unpacked into the fakefs SQLite database
// iSH's fs/fake.c models rather than into a plain directory. iSH's own
// tools/fakefsify does this against libarchive; this entry point wraps it.
//
// Returns 0 on success, a negative errno on failure (which FileRootfsStore
// reports as a failed download rather than a half-unpacked rootfs).
int32_t ish_fakefsify(const char *archive, const char *into);
