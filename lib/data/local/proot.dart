import "dart:io" show Platform;

import "../../domain/file_tools.dart";
import "../../domain/rootfs.dart";
import "../../domain/shell.dart";

/// The guest path where the project workspace is mounted: Alpine's `/root`,
/// which is also `HOME` inside the guest.
const guestHome = "/root";

/// How a command is run inside a downloaded Linux: the proot invocation, the
/// environment on both sides of it bar `HOME`, and the sentence the model is
/// told.
///
/// A pure function over paths, deliberately — what proot is asked to do is the
/// part of this feature that can be pinned by a test on a machine with no
/// Android on it.
ShellDriver prootDriver({
  required Proot proot,
  required Rootfs rootfs,
  required String rootfsDir,
  required String skillsBundledDir,
  required String userSkillsDir,
  String? abi,
}) =>
    ShellDriver(
      commandFor: (cwd, home) => [
        proot.binary,
        "-r", rootfsDir,
        "--kill-on-exit",
        "--link2symlink",
        "-0",
        "-b", "/dev",
        "-b", "/proc",
        "-b", "/sys",
        // The project workspace at a clean guest path, not its own Android
        // path. The chat's workspace is inside it, so it is reachable at
        // $guestHome + the suffix of cwd past home. The rest of the device
        // is not there.
        "-b", "$home:$guestHome",
        // Skills need a real base directory so their scripts run; bound at
        // clean paths so the model is told those, not the host's.
        "-b", "$skillsBundledDir:/opt/skills-bundled",
        "-b", "$userSkillsDir:/opt/skills",
        "-b", "${proot.tmpDir}:/tmp",
        "-b", "${proot.resolvConf}:/etc/resolv.conf",
        // The guest path of the chat workspace, not "." — proot stores -w as
        // the guest cwd, and "." resolves against the guest root, not the
        // host's working directory.
        "-w", guestWorkspacePath(guestHome, home, cwd),
        "/bin/sh",
      ],
      environment: {
        "PROOT_LOADER": proot.loader,
        if (proot.loader32 != null) "PROOT_LOADER_32": proot.loader32!,
        "PROOT_TMP_DIR": proot.tmpDir,
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C.UTF-8",
      },
      projectHome: true,
      guestRoot: guestHome,
      includeParentEnvironment: false,
      hostToGuestPaths: {
        skillsBundledDir: "/opt/skills-bundled",
        userSkillsDir: "/opt/skills",
      },
      description: "${rootfs.describe(abi)}, in which ${rootfs.packageManager} "
          "installs anything else you need. Your home directory (~) is the "
          "project workspace, and the rest of the device is not there. "
          "It is running under proot on ${Platform.operatingSystem} "
          "${Platform.operatingSystemVersion}, so filesystem-heavy commands are "
          "slower than they look",
    );
