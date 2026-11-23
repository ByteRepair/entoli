// What an `entoli://` link asks for. Read here and nowhere else; the shell
// that acts on it is `lib/ui/incoming_links.dart`.
import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart" show GZipDecoder, GZipEncoder, getCrc32;

import "bot_avatar/import.dart";
import "chat_share.dart";
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
  ///   a skill's `.skill` zip, an agent's gzipped PROMPT.md with its `name`
  ///   beside it, to install from the same page with nothing fetched. A
  ///   `def` cut short on its way here is still this link, carrying null.
  /// - `entoli://install/avatar?def=…` — a Bot Avatar definition, as JSON or
  ///   base64url JSON (Open Bot Avatar's `def` parameter), to install.
  /// - `https://share.entoli.byterepair.io/#…` — a shared chat, its zip in the
  ///   fragment, which the phones hand over where the app claims the host;
  ///   `entoli://share?def=…` is the same zip, for the viewer's Open in
  ///   Entoli on a desktop.
  static AppLink? parse(Uri uri) {
    if (uri.scheme == "https" && uri.host == shareHost) {
      return uri.fragment.isEmpty
          ? null
          : SharedChatLink(shareZipOf(uri.fragment));
    }
    if (uri.scheme != appLinkScheme) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    switch ((uri.host, segments)) {
      case ("new", []):
        return NewChatLink(uri.queryParameters["prompt"] ?? "");
      case ("share", []):
        final def = uri.queryParameters["def"];
        return def == null ? null : SharedChatLink(shareZipOf(def));
      case ("install", ["avatar"]):
        final def = uri.queryParameters["def"];
        if (def == null) return null;
        return AvatarLink(BotAvatarImport.parse(_unbase64(def)));
      case ("install", [final kind]):
        final k = CompletionKind.values.asNameMap()[kind];
        final def = uri.queryParameters["def"];
        if (k == null || def == null) return null;
        return SharedEntryLink(k, uri.queryParameters["name"], _whole(k, def));
      // A remote entry's slug has a `/` in it, so the rest of the path is it.
      case ("install", ["marketplace", "entoli", final kind, ...final rest])
          when rest.isNotEmpty:
        final k = CompletionKind.values.asNameMap()[kind];
        return k == null ? null : InstallLink(k, rest.join("/"));
    }
    return null;
  }

  /// [def] decoded, or null where it is not whole. Both formats end in what
  /// says the rest arrived — a gzip's CRC and length, a zip's end record —
  /// so a link a chat app or a command line cut short is caught here rather
  /// than installed as part of itself; a plain-text agent could not be.
  static Uint8List? _whole(CompletionKind kind, String def) {
    try {
      final raw = base64Url.decode(base64Url.normalize(def.trim()));
      return switch (kind) {
        CompletionKind.agent => _gunzipWhole(raw),
        CompletionKind.skill => zipEnds(raw) ? raw : null,
      };
      // Bad base64 is a FormatException, a bad deflate stream whatever the
      // decoder throws: either way the link did not arrive whole.
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _gunzipWhole(Uint8List raw) {
    if (raw.length < 18 || raw[0] != 0x1f || raw[1] != 0x8b) return null;
    final out = Uint8List.fromList(GZipDecoder().decodeBytes(raw));
    final trailer = ByteData.sublistView(raw, raw.length - 8);
    final crc = trailer.getUint32(0, Endian.little);
    final size = trailer.getUint32(4, Endian.little);
    final whole = size == out.length & 0xffffffff && crc == getCrc32(out);
    return whole ? out : null;
  }

  /// The link that carries [bytes] — a `.skill` zip, or an agent's PROMPT.md
  /// installed as [name] — for a friend to install. The inverse of [parse].
  static String share(CompletionKind kind, String name, Uint8List bytes) {
    final payload = kind == CompletionKind.agent
        ? GZipEncoder().encode(bytes)
        : bytes;
    final def = base64Url.encode(payload).replaceAll("=", "");
    return Uri(
      scheme: appLinkScheme,
      host: "install",
      path: "/${kind.name}",
      queryParameters: {
        if (kind == CompletionKind.agent) "name": name,
        "def": def,
      },
    ).toString();
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

/// The longest link [AppLink.share] makes: Windows hands a link over on the
/// command line, which stops at 32767 characters, and it is the tightest of
/// the five.
const appLinkMaxLength = 32000;

/// A skill or agent the link carries whole: [bytes] are a `.skill` zip or a
/// PROMPT.md, unparsed — the parsers are above the domain — and null where
/// the link was cut short. [name] is an agent's, which its file does not
/// carry.
final class SharedEntryLink extends AppLink {
  const SharedEntryLink(this.kind, this.name, this.bytes);
  final CompletionKind kind;
  final String? name;
  final Uint8List? bytes;
}

final class AvatarLink extends AppLink {
  const AvatarLink(this.import);
  final BotAvatarImport import;
}

/// A shared chat: [zip] is its data directory (see `data/chat_share.dart`),
/// null where the link was cut short.
final class SharedChatLink extends AppLink {
  const SharedChatLink(this.zip);
  final Uint8List? zip;
}
