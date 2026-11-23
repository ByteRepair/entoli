import "package:entoli_chat/app/handoff.dart";
import "package:entoli_chat/app/storage.dart";
import "package:entoli_chat/app/transcript/host.dart";
import "package:entoli_chat/core/transcript_bindings.dart";
import "package:entoli_chat/data/chat_share.dart";
import "package:entoli_chat/data/local/file_chat_store.dart";
import "package:entoli_chat/domain/chat_share.dart";
import "package:entoli_chat/domain/models.dart" show Chat;
import "package:entoli_chat/ui/chat/activity/card.dart";
import "package:entoli_chat/ui/theme.dart";
import "package:file/memory.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_web_plugins/url_strategy.dart";

import "shared_chat_hand_off.dart";
import "shared_chat_host.dart";
import "shared_chat_page.dart";
import "web_hand_offs.dart";

/// The data directory a shared chat is unpacked into. A browser has no disk,
/// so it is in memory.
const _dataDir = "/entoli";

Future<void> main() async {
  // The chat is the fragment, which Flutter's routing would rewrite.
  setUrlStrategy(null);
  WidgetsFlutterBinding.ensureInitialized();
  final fs = MemoryFileSystem(style: FileSystemStyle.posix);
  final payload = Uri.base.fragment;
  final zip = payload.isEmpty ? null : shareZipOf(payload);
  final unpacked = zip == null
      ? null
      : await unpackShare(zip, fs.directory(_dataDir));
  Widget home = const _NotAShare();
  var overrides = transcriptOverrides;
  if (unpacked case (:final config, :final chatId)) {
    final store = FileChatStore(config);
    final Chat chat;
    try {
      chat = await store.load(chatId);
    } catch (_) {
      // The page says so; nothing else here would.
      runApp(const MaterialApp(home: _NotAShare()));
      return;
    }
    // A chat shared without its workspace has none to unpack; an empty one
    // is what the explorer says that of.
    fs.directory(config.workspaceDir(chatId)).createSync(recursive: true);
    overrides = [
      ...transcriptOverrides,
      fileSystemProvider.overrideWithValue(fs),
      transcriptHostProvider.overrideWithValue(
        SharedChatHost(chat, store: store, config: config),
      ),
      transcriptHandOffProvider.overrideWithValue(SharedChatHandOff.new),
      fileHandoffProvider.overrideWithValue(WebFileHandoff(fs)),
      linkOpenerProvider.overrideWithValue(WebLinkOpener(fs, store)),
    ];
    home = SharedChatPage(chat: chat, payload: payload);
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
