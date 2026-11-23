import "dart:io";

import "package:agent_chat/app/handoff.dart";
import "package:agent_chat/app/transcript/host.dart";
import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/transcript_bindings.dart";
import "package:agent_chat/data/chat_share.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/chat_share.dart";
import "package:agent_chat/ui/chat/activity/card.dart";
import "package:agent_chat/ui/theme.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_web_plugins/url_strategy.dart";

import "memory_io.dart";
import "shared_chat_hand_off.dart";
import "shared_chat_host.dart";
import "shared_chat_page.dart";
import "web_hand_offs.dart";

/// The data directory a shared chat is unpacked into, in memory.
const _dataDir = "/entoli";

Future<void> main() async {
  // The chat is the fragment, which Flutter's routing would rewrite.
  setUrlStrategy(null);
  WidgetsFlutterBinding.ensureInitialized();
  useMemoryFileSystem();
  final payload = Uri.base.fragment;
  final zip = payload.isEmpty ? null : shareZipOf(payload);
  final chatId = zip == null ? null : await unpackShare(zip, _dataDir);
  Widget home = const _NotAShare();
  var overrides = transcriptOverrides;
  if (chatId != null) {
    final config = await AppConfig.load(_dataDir);
    final store = FileChatStore(config);
    final chat = await store.load(chatId);
    // A chat shared without its workspace has none to unpack; an empty one
    // is what the explorer says that of.
    final workspace = config.workspaceDir(chatId);
    Directory(workspace).createSync(recursive: true);
    overrides = [
      ...transcriptOverrides,
      transcriptHostProvider.overrideWithValue(
        SharedChatHost(chat, store: store, config: config),
      ),
      transcriptHandOffProvider.overrideWithValue(SharedChatHandOff.new),
      fileHandoffProvider.overrideWithValue(const WebFileHandoff()),
      linkOpenerProvider.overrideWithValue(WebLinkOpener(store)),
    ];
    home = SharedChatPage(chat: chat, payload: payload, workspace: workspace);
  }
  runApp(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        title: "Entoli",
        debugShowCheckedModeBanner: false,
        theme: entoliTheme(Brightness.light),
        darkTheme: entoliTheme(Brightness.dark),
        home: home,
      ),
    ),
  );
}

class _NotAShare extends StatelessWidget {
  const _NotAShare();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text("This link is incomplete or not a shared chat.")),
  );
}
