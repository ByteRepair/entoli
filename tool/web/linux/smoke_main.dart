// The browser's Linux end to end, without the app around it: the real worker,
// v86, image, 9p server and shell, driven from one page that prints what each
// step did. Run by smoke.sh, which reads the console of a headless Chromium.
// ignore_for_file: avoid_print
import "dart:convert";

import "package:agent_chat/core/platform/web/platform.dart" as web;

Future<void> main() async {
  final fs = web.createFileSystem();
  final data = await web.dataDir();
  final workspace = "$data/projects/default/workspace";
  final chat = "$workspace/chats/smoke";
  await fs.file("$data/projects/default/skills-bundled/demo/SKILL.md")
      .create(recursive: true);
  await fs.directory(workspace).create(recursive: true);
  await fs.file("$workspace/from-the-app.txt").writeAsString("written by the app");

  await web.installBundledTools("");
  final shell = web.platformShell(
      environment: () => const {}, driver: () => null, dataDir: data);
  print("SMOKE available ${shell.canRunCommands}: ${shell.platformDescription}");

  Future<void> run(String command, {bool oneShot = false}) async {
    final started = DateTime.now();
    final result = await shell
        .start(command,
            cwd: chat,
            home: workspace,
            timeout: const Duration(minutes: 5),
            oneShot: oneShot)
        .result;
    final ms = DateTime.now().difference(started).inMilliseconds;
    // One line each: the browser's log splits a message at its newlines.
    print("SMOKE \$ $command => rc=${result.returnCode} ${ms}ms "
        "cwd=${result.cwd} ${result.exceptionInfo ?? ""} "
        "${jsonEncode(result.output)}");
  }

  await run("uname -m; cat /etc/alpine-release; pwd; echo \$HOME");
  await run("cat ../../from-the-app.txt; echo made-in-guest > ../../from-the-guest.txt");
  print("SMOKE app reads: ${await fs.file("$workspace/from-the-guest.txt").readAsString()}");
  await run("ls $data $data/projects/default; ls $data/projects/default/skills-bundled/demo");
  await run("touch $data/projects/default/skills-bundled/demo/x 2>&1; cat $data/settings.json 2>&1");
  await run("cd .. && mkdir -p repo && cd repo && git init -q && echo hi > a && "
      "chmod +x a && git add a && git -c user.name=t -c user.email=t@t commit -qm one && "
      "git log --oneline && git status --short && ls -l a");
  await run("pwd");
  await run("python3 -c 'import sys; print(sys.version.split()[0])'");
  await run("printf 'x%.0s' \$(seq 1 50000) | wc -c");
  await run("seq 1 3; exit 3", oneShot: true);
  final slow = shell.start("sleep 60",
      cwd: chat, home: workspace, timeout: const Duration(minutes: 5));
  await Future<void>.delayed(const Duration(seconds: 2));
  await slow.kill();
  final stopped = await slow.result;
  print("SMOKE stop: rc=${stopped.returnCode} ${stopped.exceptionInfo}");
  await run("echo still here; pwd");
  print("SMOKE done");
}
