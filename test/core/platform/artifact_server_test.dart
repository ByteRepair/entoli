import "dart:io";

import "package:agent_chat/core/platform/io/artifact_server.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("artifact-server-");
    root = p.join(tmp.path, "site");
    Directory(root).createSync();
    File(p.join(root, "index.html")).writeAsStringSync("<p>hi</p>");
    File(p.join(tmp.path, "secret.txt")).writeAsStringSync("secret");
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<(int, String)> get(String base, String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse("$base$path"));
      final res = await req.close();
      final body = await res.transform(const SystemEncoding().decoder).join();
      return (res.statusCode, body);
    } finally {
      client.close(force: true);
    }
  }

  test("serves the index", () async {
    final server = await IoArtifactServer.start(root);
    addTearDown(server.stop);
    final (status, body) = await get(server.baseUrl, "/");
    expect(status, 200);
    expect(body, contains("hi"));
  });

  test("an encoded dot segment cannot leave the root", () async {
    final server = await IoArtifactServer.start(root);
    addTearDown(server.stop);
    final (status, body) = await get(server.baseUrl, "/..%2Fsecret.txt");
    expect(status, 404);
    expect(body, isNot(contains("secret\n")));
    expect(body, isNot(equals("secret")));
  });
}
