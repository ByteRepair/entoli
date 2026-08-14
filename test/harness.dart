import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/providers.dart";

import "fakes.dart";

/// The app over a throwaway data directory, with the backend faked. Create one
/// per test and [dispose] it in `tearDown`.
class TestApp {
  TestApp._(this.tmp, this.config, this.backend, this.container);

  factory TestApp.create({Duration? stallTimeout}) {
    final tmp = Directory.systemTemp.createTempSync("agent_chat_test_");
    final config = AppConfig.forDirectory(tmp);
    Directory(config.chatsDir.path).createSync(recursive: true);
    final backend = FakeBackend();
    return TestApp._(
      tmp,
      config,
      backend,
      ProviderContainer(
        overrides: [
          chatStoreProvider.overrideWithValue(LocalChatStore(config)),
          agentBackendProvider.overrideWithValue(backend),
          appConfigProvider.overrideWithValue(config),
          if (stallTimeout != null) turnStallTimeoutProvider.overrideWithValue(stallTimeout),
        ],
      ),
    );
  }

  final Directory tmp;
  final AppConfig config;
  final FakeBackend backend;
  final ProviderContainer container;

  ChatRepository get repo => container.read(chatRepositoryProvider);

  /// The app-level default, as if a previous run had saved it.
  void seedGlobalDefault({String? providerId, String? modelId}) =>
      config.settingsFile.writeAsStringSync(jsonEncode({
        "defaultProviderId": ?providerId,
        "defaultModelId": ?modelId,
      }));

  /// A chat's own overrides, as if the chat settings page had saved them.
  void seedChatMeta(String chatId, Map<String, dynamic> json) {
    Directory(config.chatDir(chatId).path).createSync(recursive: true);
    config.metaFile(chatId).writeAsStringSync(jsonEncode(json));
  }

  ChatMeta savedMeta(String chatId) => ChatMeta.fromFile(config.metaFile(chatId));

  /// Pump [child] as the whole app.
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: MaterialApp(home: child)),
    );
    await tester.pumpAndSettle();
  }

  void dispose() {
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// Open one of the two provider/model dropdowns.
Future<void> openDropdown(WidgetTester tester, {required bool model}) async {
  final dropdowns = find.byType(DropdownButtonFormField<String?>);
  await tester.tap(model ? dropdowns.last : dropdowns.first);
  await tester.pumpAndSettle();
}

/// Item labels of the open dropdown popup, which renders in its own ListView
/// above the page's.
List<String?> popupLabels(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
      of: find.byType(ListView).last,
      matching: find.byType(Text),
    ))
    .map((t) => t.data)
    .toList();
