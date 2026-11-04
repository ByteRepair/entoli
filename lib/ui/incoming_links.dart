import "dart:async";

import "package:app_links/app_links.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/log.dart";
import "../domain/app_link.dart";
import "../providers.dart";
import "bot_avatar/bot_avatar_install.dart";
import "marketplace/marketplace.dart";
import "marketplace/marketplace_entry_preview.dart";
import "selection.dart";
import "widgets/dialogs.dart";

/// Wraps the app so an `entoli://` link opens what it names over whatever is
/// on screen. `app_links` delivers the link that launched the app and every
/// one after on the one stream.
class IncomingLinks extends ConsumerStatefulWidget {
  const IncomingLinks({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingLinks> createState() => _IncomingLinksState();
}

class _IncomingLinksState extends ConsumerState<IncomingLinks> {
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    try {
      _links = AppLinks().uriLinkStream.listen(_open);
    } on Object catch (e) {
      // A test host has no plugin behind the channel.
      logFailure("links", "cannot listen for entoli:// links", e);
    }
  }

  @override
  void dispose() {
    _links?.cancel();
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
        openNewChat(context, ref);
        ref.read(newChatPromptProvider.notifier).set(prompt);
      case AvatarLink(:final import):
        await navigator.push(
          MaterialPageRoute(builder: (_) => BotAvatarInstallPage(import: import)),
        );
      case InstallLink(:final kind, :final slug):
        final MarketplaceEntry entry;
        try {
          final entries = await fetchMarketplaceEntries(
            ref.read(marketplaceClientProvider),
            kind,
          );
          entry = entries.firstWhere((e) => e.slug == slug);
        } on Object catch (e) {
          logFailure("links", "no marketplace ${kind.name} $slug", e);
          if (mounted) say(context, "Could not find $slug in the marketplace.");
          return;
        }
        await navigator.push(
          MaterialPageRoute(
            builder: (_) => MarketplaceEntryPreviewPage(kind: kind, entry: entry),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
