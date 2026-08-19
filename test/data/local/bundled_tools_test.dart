import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/bundled_tools.dart";

void main() {
  late Directory root;
  late Directory libDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync("agent_chat_tools_root_");
    libDir = Directory.systemTemp.createTempSync("agent_chat_tools_lib_");
  });
  tearDown(() {
    for (final dir in [root, libDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  void ship(String name) => File(p.join(libDir.path, name)).writeAsStringSync("elf");

  Future<Map<String, String>?> install() =>
      BundledTools.install(root: root.path, libDir: libDir.path);

  test("a build that ships nothing changes nothing", () async {
    expect(await install(), isNull);
    expect(root.listSync(), isEmpty);
  });

  test("git is on the PATH, as a link into the one directory it may run from",
      () async {
    ship("libgit.so");

    final environment = (await install())!;

    final git = Link(p.join(root.path, "bin", "git"));
    expect(git.existsSync(), isTrue);
    expect(git.targetSync(), p.join(libDir.path, "libgit.so"));
    expect(environment["PATH"], startsWith(p.join(root.path, "bin")));
  });

  test("the system's own commands stay on the PATH behind it", () async {
    ship("libgit.so");

    expect((await install())!["PATH"], contains(":"));
  });

  test("the https helper is linked under every scheme git looks it up by",
      () async {
    ship("libgit.so");
    ship("libgit-remote-http.so");

    final environment = (await install())!;

    final execPath = environment["GIT_EXEC_PATH"]!;
    for (final scheme in const ["http", "https", "ftp", "ftps"]) {
      expect(Link(p.join(execPath, "git-remote-$scheme")).existsSync(), isTrue,
          reason: "git resolves its remote helpers by name");
    }
  });

  test("a build without the helper still offers git", () async {
    ship("libgit.so");

    final environment = (await install())!;

    expect(environment["GIT_EXEC_PATH"], isNotNull);
    expect(
        Link(p.join(environment["GIT_EXEC_PATH"]!, "git-remote-https")).existsSync(),
        isFalse);
  });

  test("certificates come from the system's own store", () async {
    ship("libgit.so");

    expect((await install())!["SSL_CERT_DIR"], "/system/etc/security/cacerts");
  });

  test("a link left by the install before this one is repointed", () async {
    ship("libgit.so");
    await install();
    final moved = Directory.systemTemp.createTempSync("agent_chat_tools_lib2_");
    addTearDown(() => moved.deleteSync(recursive: true));
    File(p.join(moved.path, "libgit.so")).writeAsStringSync("elf");

    // What an app update does: the library directory's path carries an
    // install-specific segment, so every link from before it points at nothing.
    await BundledTools.install(root: root.path, libDir: moved.path);

    expect(Link(p.join(root.path, "bin", "git")).targetSync(),
        p.join(moved.path, "libgit.so"));
  });

  test("a temporary directory of its own, since the system's is not writable",
      () async {
    ship("libgit.so");

    final tmp = (await install())!["TMPDIR"]!;
    expect(Directory(tmp).existsSync(), isTrue);
  });
}
