import "dart:io";

import "package:archive/archive_io.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/host_tools.dart";

import "../../harness.dart" show tempDir;

void main() {
  late Directory root;
  late String workspace;
  late HostTools tools;

  setUp(() {
    // Resolved: the shim's PWD is the real path, past macOS's /var link.
    root = Directory(tempDir("host-tools-test").resolveSymbolicLinksSync());
    workspace = p.join(root.path, "workspace");
    Directory(workspace).createSync();
    tools = HostTools(
      p.join(root.path, "host-tools"),
      mounts: () => [(guest: "/root", host: workspace)],
    )..install();
  });
  tearDown(() => tools.stop());

  /// A zip at [path] holding an executable `bin/tool` and a `README`.
  void writeZip(String path) {
    final archive = Archive()
      ..add(
        ArchiveFile.bytes("bin/tool", "#!/bin/sh\n".codeUnits)..mode = 0x1ed,
      )
      ..add(ArchiveFile.string("README", "hello"));
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test(
    "an unzip on the workspace is done here, the execute bit kept",
    () async {
      writeZip(p.join(workspace, "a.zip"));

      final answer = await tools.run("unzip", "/root", [
        "-o",
        "a.zip",
        "-d",
        "x",
      ]);

      expect(answer, isNotNull);
      expect(answer!.code, 0);
      expect(answer.output, contains("inflating: bin/tool"));
      final tool = File(p.join(workspace, "x", "bin", "tool"));
      expect(tool.readAsStringSync(), "#!/bin/sh\n");
      expect(tool.statSync().mode & 0x40, isNot(0));
    },
  );

  test("a tar whose name says nothing is read by its first bytes", () async {
    final tar = TarEncoder().encode(
      Archive()..add(ArchiveFile.string("dir/file", "x")),
    );
    File(
      p.join(workspace, "blob"),
    ).writeAsBytesSync(const GZipEncoder().encode(tar));

    final answer = await tools.run("tar", "/root/sub/..", [
      "xf",
      "blob",
      "-C",
      "out",
    ]);

    expect(answer!.code, 0, reason: answer.output);
    expect(
      File(p.join(workspace, "out", "dir", "file")).readAsStringSync(),
      "x",
    );
  });

  test("a path off every host mount is the guest's", () async {
    writeZip(p.join(workspace, "a.zip"));

    expect(
      await tools.run("unzip", "/root", ["a.zip", "-d", "/tmp/x"]),
      isNull,
    );
    expect(await tools.run("unzip", "/tmp", ["a.zip"]), isNull);
  });

  test("a form the host does not take is the guest's", () async {
    writeZip(p.join(workspace, "a.zip"));

    for (final (tool, args) in [
      ("unzip", ["-l", "a.zip"]),
      ("unzip", ["a.zip", "README"]),
      ("tar", ["cf", "a.tar", "x"]),
      ("tar", ["xf", "-"]),
      ("gzip", ["a"]),
    ]) {
      expect(
        await tools.run(tool, "/root", args),
        isNull,
        reason: "$tool $args",
      );
    }
  });

  test("an unzip that would replace a file asks the guest's tool, unless "
      "told to overwrite", () async {
    writeZip(p.join(workspace, "a.zip"));
    File(p.join(workspace, "README")).writeAsStringSync("mine");

    expect(await tools.run("unzip", "/root", ["a.zip"]), isNull);
    expect(File(p.join(workspace, "README")).readAsStringSync(), "mine");

    expect((await tools.run("unzip", "/root", ["-o", "a.zip"]))!.code, 0);
    expect(File(p.join(workspace, "README")).readAsStringSync(), "hello");
  });

  test("an archive not on the host's disk is the guest's tool's", () async {
    expect(await tools.run("unzip", "/root", ["gone.zip"]), isNull);
  });

  group("downloads", () {
    late List<Uri> asked;

    /// The host's tools over [respond], each request recorded in [asked].
    HostTools over(Future<http.Response> Function(http.Request) respond) {
      asked = [];
      return HostTools(
        tools.dir,
        mounts: () => [(guest: "/root", host: workspace)],
        client: () => MockClient((request) {
          asked.add(request.url);
          return respond(request);
        }),
      );
    }

    const url = "https://example.com/esbmc.zip";

    test("the setup's wget lands in the workspace", () async {
      final host = over((_) async => http.Response("zip bytes", 200));

      final answer = await host.run("wget", "/root", [
        "-q",
        "-T",
        "30",
        "-O",
        "/root/esbmc.zip",
        url,
      ]);

      expect(answer!.code, 0);
      expect(answer.output, isEmpty);
      expect(asked, [Uri.parse(url)]);
      expect(
        File(p.join(workspace, "esbmc.zip")).readAsStringSync(),
        "zip bytes",
      );
    });

    test("an HTTP error fails wget and leaves no file", () async {
      final host = over((_) async => http.Response("", 404));

      final answer = await host.run("wget", "/root", ["-O", "a.zip", url]);

      expect(answer!.code, 1);
      expect(answer.output, contains("404"));
      expect(File(p.join(workspace, "a.zip")).existsSync(), isFalse);
    });

    test("curl retries a network failure as many times as told", () async {
      var calls = 0;
      final host = over((_) async {
        if (++calls < 3) throw http.ClientException("reset");
        return http.Response("zip bytes", 200);
      });

      final answer = await host.run("curl", "/root", [
        "-fsSL",
        "--connect-timeout",
        "30",
        "--retry",
        "2",
        "-o",
        "a.zip",
        url,
      ]);

      expect(answer!.code, 0);
      expect(calls, 3);
      expect(File(p.join(workspace, "a.zip")).existsSync(), isTrue);
    });

    test("curl without --fail keeps the error body, as curl does", () async {
      final host = over((_) async => http.Response("not here", 404));

      final answer = await host.run("curl", "/root", ["-o", "a.html", url]);

      expect(answer!.code, 0);
      expect(File(p.join(workspace, "a.html")).readAsStringSync(), "not here");
    });

    test("a download the shim gave up on stops and leaves nothing", () async {
      final host = HostTools(
        tools.dir,
        mounts: () => [(guest: "/root", host: workspace)],
        client: () => MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable(["a".codeUnits, "b".codeUnits]),
            200,
          ),
        ),
      );

      final answer = await host.run("wget", "/root", [
        "-O",
        "a.zip",
        url,
      ], abandoned: () => true);

      expect(answer!.code, 130);
      expect(File(p.join(workspace, "a.zip")).existsSync(), isFalse);
    });

    test("forms the host does not take are the guest's", () async {
      final host = over((_) async => http.Response("", 200));
      for (final (tool, args) in [
        ("wget", [url]),
        ("wget", ["-O", "-", url]),
        ("wget", ["-c", "-O", "a.zip", url]),
        ("wget", ["-O", "/opt/a.zip", url]),
        ("wget", ["-O", "missing/a.zip", url]),
        ("wget", ["-O", "a.zip", "ftp://example.com/a.zip"]),
        ("curl", [url]),
        ("curl", ["-o", "-", url]),
        ("curl", ["-H", "X: y", "-o", "a.zip", url]),
        ("curl", ["-d", "x", "-o", "a.zip", url]),
      ]) {
        expect(
          await host.run(tool, "/root", args),
          isNull,
          reason: "$tool $args",
        );
      }
      expect(asked, isEmpty);
    });
  });

  group("the shim", () {
    late String stubs;

    setUp(() {
      // The guest's own unzip, where the host falls back to it.
      stubs = p.join(root.path, "stubs");
      Directory(stubs).createSync();
      final guest = File(p.join(stubs, "unzip"))
        ..writeAsStringSync('#!/bin/sh\necho "guest unzip \$*"\n');
      Process.runSync("chmod", ["+x", guest.path]);
    });

    /// The shim, run from [cwd] on the host with the guest's paths standing
    /// for themselves: the test's mount is the workspace at its own path.
    Future<ProcessResult> shim(List<String> args) => Process.run(
      p.join(tools.binDir, "unzip"),
      args,
      workingDirectory: workspace,
      environment: {"PATH": "${tools.binDir}:$stubs:/usr/bin:/bin"},
    );

    test("prints what the host did and exits with its code", () async {
      // The shim runs on the host, so the guest's path is the host's.
      tools = HostTools(
        tools.dir,
        mounts: () => [(guest: workspace, host: workspace)],
      )..start();
      writeZip(p.join(workspace, "a.zip"));

      final result = await shim(["-q", "a.zip", "-d", "x"]);

      expect(result.exitCode, 0, reason: "${result.stderr}");
      expect(File(p.join(workspace, "x", "README")).existsSync(), isTrue);
      expect(Directory(tools.callsDir).listSync(), isEmpty);
    });

    test("runs the guest's own tool where the host falls back", () async {
      tools.start();
      final result = await shim(["-l", "a.zip"]);

      expect(result.stdout, "guest unzip -l a.zip\n");
    });
  });
}
