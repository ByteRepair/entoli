import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/bundled_tools.dart";
import "package:agent_chat/domain/shell.dart";

void main() {
  // Laying proot out asks Android for the network's resolvers, and a method
  // channel needs a binding even to answer that nothing is listening.
  TestWidgetsFlutterBinding.ensureInitialized();

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

  void shipProot() {
    ship("libproot.so");
    ship("libproot-loader.so");
  }

  Future<Toolset?> install() =>
      BundledTools.install(root: root.path, libDir: libDir.path);

  test("a build that ships nothing changes nothing", () async {
    expect(await install(), isNull);
    expect(root.listSync(), isEmpty);
  });

  test("a build with only the loader ships no proot, and so no toolset",
      () async {
    ship("libproot-loader.so");

    expect(await install(), isNull);
  });

  test("proot on its own is a toolset, since it is what a command runs inside",
      () async {
    shipProot();

    final tools = await install();
    expect(tools, isNotNull);
    expect(tools!.proot, isNotNull);
  });

  // The prompt names `Toolset.names`, so a name here is a claim the shell can
  // run that command. Nothing is laid out by name any more, and a build that
  // starts claiming one without laying it out is the half-failure this is for.
  test("nothing is advertised by name, since nothing is laid out under one",
      () async {
    shipProot();

    expect((await install())!.names, isNull);
  });

  test("a temporary directory of its own, since the system's is not writable",
      () async {
    shipProot();

    final tmp = (await install())!.environment["TMPDIR"]!;
    expect(Directory(tmp).existsSync(), isTrue);
  });
}
