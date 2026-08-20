import "../../domain/rootfs.dart";
import "../../domain/shell.dart";

/// How a command is run inside a downloaded Linux: the proot invocation, the
/// environment on both sides of it, and the sentence the model is told.
///
/// A pure function over paths, deliberately — what proot is asked to do is the
/// whole of this feature's behaviour, and it is the one part of it that can be
/// pinned by a test on a machine with no Android on it.
Sandbox prootSandbox({
  required Proot proot,
  required Rootfs rootfs,
  required String rootfsDir,
  required String dataDir,
  String? abi,
}) =>
    Sandbox(
      command: [
        proot.binary,
        "-r", rootfsDir,
        // The tracees are killed with the tracer. Without it a timed-out build
        // is merely detached from proot and carries on running.
        "--kill-on-exit",
        // A hard link is what a package manager unpacks with, and app storage
        // does not always allow one.
        "--link2symlink",
        // The guest believes it is root, which is what lets it install
        // packages. It is a lie told to the guest, not a privilege: the process
        // is still the app's own uid to the kernel.
        "-0",
        "-b", "/dev",
        "-b", "/proc",
        "-b", "/sys",
        // At its own path, not somewhere tidier. Every path the app has ever
        // handed the model — the chat's workspace, the project's, an artifact —
        // then means the same thing inside the guest as outside it, and nothing
        // else in the app has to learn that commands are running elsewhere.
        "-b", "$dataDir:$dataDir",
        "-b", "${proot.tmpDir}:/tmp",
        // Android keeps no such file, so the guest is given one — see
        // `BundledTools`, which writes it at every launch.
        "-b", "${proot.resolvConf}:/etc/resolv.conf",
        // The directory the process was started in, which proot would otherwise
        // replace with `/`. It reads the same either way round — as a host path
        // or as a guest one — which is what the bind above buys.
        "-w", ".",
        "/bin/sh",
      ],
      environment: {
        // proot's own, read before it has traced anything. The loader is the
        // one file that is really exec'd, so it has to be named where it is
        // allowed to be: the native library directory.
        "PROOT_LOADER": proot.loader,
        if (proot.loader32 != null) "PROOT_LOADER_32": proot.loader32!,
        // proot writes its own temporary files here. The system's temporary
        // directory is not somewhere an app may write.
        "PROOT_TMP_DIR": proot.tmpDir,
        // Everything below this line is the guest's rather than proot's.
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root",
        "LANG": "C.UTF-8",
      },
      description: "${rootfs.describe(abi)}, in which ${rootfs.packageManager} "
          "installs anything else you need. The chat's files are at the same "
          "paths inside it as outside, and the rest of the device is not there",
    );
