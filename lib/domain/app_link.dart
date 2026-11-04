// What an `entoli://` link asks for. Read here and nowhere else; the shell
// that acts on it is `lib/ui/incoming_links.dart`.
import "dart:convert";
import "dart:io" show gzip;
import "dart:typed_data";

import "bot_avatar/import.dart";
import "models.dart";

/// The scheme every platform registers Entoli for.
const appLinkScheme = "entoli";

sealed class AppLink {
  const AppLink();

  /// [uri] as a link, or null where it is not one Entoli understands.
  ///
  /// - `entoli://new?prompt=…` — a new chat with the prompt in its composer,
  ///   unsent: the form harness links take (Open Bot Avatar's among them).
  /// - `entoli://install/marketplace/entoli/<skill|agent>/<slug>` — a
  ///   marketplace entry's install page. `entoli` is the marketplace, the one
  ///   there is.
  /// - `entoli://install/<skill|agent>?def=…` — the entry itself, base64url:
  ///   a skill's `.skill` zip, an agent's PROMPT.md (gzipped or not), to
  ///   install from the same page with nothing fetched.
  /// - `entoli://install/avatar?def=…` — a Bot Avatar definition, as JSON or
  ///   base64url JSON (Open Bot Avatar's `def` parameter), to install.
  static AppLink? parse(Uri uri) {
    if (uri.scheme != appLinkScheme) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    switch ((uri.host, segments)) {
      case ("new", []):
        return NewChatLink(uri.queryParameters["prompt"] ?? "");
      case ("install", ["avatar"]):
        final def = uri.queryParameters["def"];
        if (def == null) return null;
        return AvatarLink(BotAvatarImport.parse(_unbase64(def)));
      case ("install", [final kind]):
        final k = CompletionKind.values.asNameMap()[kind];
        final def = uri.queryParameters["def"];
        if (k == null || def == null) return null;
        final bytes = _bytes(def);
        return bytes == null ? null : SharedEntryLink(k, bytes);
      // A remote entry's slug has a `/` in it, so the rest of the path is it.
      case ("install", ["marketplace", "entoli", final kind, ...final rest])
          when rest.isNotEmpty:
        final k = CompletionKind.values.asNameMap()[kind];
        return k == null ? null : InstallLink(k, rest.join("/"));
    }
    return null;
  }

  /// [def] base64url-decoded and, where it is gzip, inflated. Null where it
  /// is neither, or does not inflate.
  static Uint8List? _bytes(String def) {
    try {
      final raw = base64Url.decode(base64Url.normalize(def.trim()));
      final gzipped = raw.length > 1 && raw[0] == 0x1f && raw[1] == 0x8b;
      return gzipped ? Uint8List.fromList(gzip.decode(raw)) : raw;
      // Bad base64 is a FormatException; a bad gzip stream, whatever zlib
      // throws. Either way the link carries nothing.
    } catch (_) {
      return null;
    }
  }

  /// [def] as text: base64url JSON decoded, anything else as it came.
  static String _unbase64(String def) {
    if (def.trimLeft().startsWith(RegExp(r"[\[{]"))) return def;
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(def.trim())));
    } on FormatException {
      return def;
    }
  }
}

final class NewChatLink extends AppLink {
  const NewChatLink(this.prompt);
  final String prompt;
}

final class InstallLink extends AppLink {
  const InstallLink(this.kind, this.slug);
  final CompletionKind kind;
  final String slug;
}

/// A skill or agent the link carries whole: [bytes] are a `.skill` zip or a
/// PROMPT.md, unparsed — the parsers are above the domain.
final class SharedEntryLink extends AppLink {
  const SharedEntryLink(this.kind, this.bytes);
  final CompletionKind kind;
  final Uint8List bytes;
}

final class AvatarLink extends AppLink {
  const AvatarLink(this.import);
  final BotAvatarImport import;
}
