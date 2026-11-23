import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/log.dart";
import "../domain/app_link.dart";
import "../providers.dart";
import "../app/chat_shares.dart";
import "../app/marketplace/preview.dart";
import "bot_avatar/bot_avatar_install.dart";
import "marketplace/marketplace_entry_preview.dart";
import "selection.dart";
import "widgets/dialogs.dart";

/// Wraps the app so an `entoli://` link opens what it names over whatever is
/// on screen. [appLinksProvider] delivers the link that launched the app and
/// every one after on the one stream.
class IncomingLinks extends ConsumerStatefulWidget {
  const IncomingLinks({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingLinks> createState() => _IncomingLinksState();
}

class _IncomingLinksState extends ConsumerState<IncomingLinks> {
  late final StreamSubscription<Uri> _links;

  @override
  void initState() {
    super.initState();
    _links = ref
        .read(appLinksProvider)
        .listen(
          _open,
          onError: (Object e) =>
              logFailure("links", "cannot listen for entoli:// links", e),
        );
  }

  @override
  void dispose() {
    _links.cancel();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    final link = AppLink.parse(uri);
    if (link == null) {
      logFailure("links", "not a link Entoli understands", uri.host);
      return;
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    switch (link) {
      case NewChatLink(:final prompt):
        navigator.popUntil((r) => r.isFirst);
        openNewChat(context, ref, prompt: prompt);
      case SharedEntryLink(:final kind):
        final (entry, preview) = sharedEntry(link);
        if (link.bytes == null) {
          logFailure("links", "a shared ${kind.name} link arrived cut short");
        }
        unawaited(
          openMarketplaceEntry(
            context,
            kind: kind,
            entry: entry,
            preview: preview,
          ),
        );
      case AvatarLink(:final import):
        unawaited(openBotAvatarInstall(context, import));
      case SharedChatLink(:final zip):
        if (zip == null) {
          logFailure("links", "a shared chat link arrived cut short");
          say(context, "This shared chat's link arrived cut short.");
          return;
        }
        navigator.popUntil((r) => r.isFirst);
        final id = await ref.read(chatSharesProvider).import(zip);
        if (id == null && mounted) {
          logFailure("links", "a shared chat link held no chat");
          say(context, "This link does not hold a shared chat.");
        }
      case InstallLink(:final kind, :final slug):
        // The provider logs a failed fetch; a missing slug is this one's.
        final entries = await ref
            .read(marketplaceEntriesProvider(kind).future)
            .then((listing) => listing.entries)
            .catchError((Object _) => const <Never>[]);
        final entry = entries.where((e) => e.slug == slug).firstOrNull;
        if (!mounted) return;
        if (entry == null) {
          logFailure("links", "no marketplace ${kind.name}", slug);
          say(context, "Could not find $slug in the marketplace.");
          return;
        }
        unawaited(openMarketplaceEntry(context, kind: kind, entry: entry));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
