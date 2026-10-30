import "dart:io";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_trigger_store.dart";
import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

void main() {
  late AppConfig config;
  late List<String> logged;
  late DebugPrintCallback saved;

  setUp(() async {
    config = await loadedTempConfig();
    logged = [];
    saved = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add(message ?? "");
  });

  tearDown(() => debugPrint = saved);

  test("no reminders.json yet is an empty list and no log line", () async {
    expect(await FileTriggerStore(config).load(), isEmpty);
    expect(logged, isEmpty);
  });

  test("a reminders.json that does not parse still logs", () async {
    await File(config.remindersFile).writeAsString("{not json");

    expect(await FileTriggerStore(config).load(), isEmpty);
    expect(logged, [startsWith("[triggers]")]);
  });
}
