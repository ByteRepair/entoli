// What an `entoli://` link asks for. Read here and nowhere else; the shell
// that acts on it is `lib/ui/incoming_links.dart`.
import "dart:convert";

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
  /// - `entoli://install/skill/<slug>`, `entoli://install/agent/<slug>` — a
  ///   marketplace entry's install page.
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
      // A remote entry's slug has a `/` in it, so the rest of the path is it.
      case ("install", [final kind, ...final rest]) when rest.isNotEmpty:
        final k = CompletionKind.values.asNameMap()[kind];
        return k == null ? null : InstallLink(k, rest.join("/"));
    }
    return null;
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

final class AvatarLink extends AppLink {
  const AvatarLink(this.import);
  final BotAvatarImport import;
}
