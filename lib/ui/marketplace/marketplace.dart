import "dart:convert";
import "dart:typed_data";

import "package:http/http.dart" as http;

import "../../domain/models.dart";

/// What the marketplace site lives at. A const until there is a reason to
/// move it; the section path is [CompletionKind.folder], the site's own.
const marketplaceBaseUrl = "https://byterepair.github.io/entoli-marketplace";

/// One entry of the marketplace, as an `index.json` names it. The fields are
/// the site's five; `version` and `tags` are there only when the entry's
/// frontmatter set them.
class MarketplaceEntry {
  const MarketplaceEntry({
    required this.slug,
    required this.name,
    required this.description,
    required this.author,
    this.version,
    this.tags = const [],
  });

  final String slug;
  final String name;
  final String description;
  final String author;
  final String? version;
  final List<String> tags;

  /// The line under the description wherever the entry is drawn — the list's
  /// row and the preview's header alike read it, so the two cannot drift.
  String get metaLine => [
        if (author.isNotEmpty) author,
        if (version != null) "v$version",
        ...tags,
      ].join(" · ");

  factory MarketplaceEntry.fromJson(String slug, Map<String, Object?> json) =>
      MarketplaceEntry(
        slug: slug,
        name: (json["name"] as String?) ?? slug,
        description: (json["description"] as String?) ?? "",
        author: (json["author"] as String?) ?? "",
        version: json["version"] as String?,
        tags: (json["tags"] as List<Object?>?)?.cast<String>() ?? const [],
      );
}

/// The marketplace's list for [kind]. Throws on anything it cannot read, so
/// the page decides what an unreachable marketplace looks like.
Future<List<MarketplaceEntry>> fetchMarketplaceEntries(
  http.Client client,
  CompletionKind kind,
) async {
  final uri = Uri.parse("$marketplaceBaseUrl/${kind.folder}/index.json");
  final body = utf8.decode((await client.get(uri)).bodyBytes);
  final json = jsonDecode(body) as Map<String, Object?>;
  return [
    for (final MapEntry(:key, :value) in json.entries)
      MarketplaceEntry.fromJson(key, value as Map<String, Object?>),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// One file of one entry: `README.md`, `PROMPT.md`, `profile.png`. Null is a
/// 404 — a file the entry does not carry (a picture, most often), which is
/// an answer rather than a failure; anything else that goes wrong throws, so
/// the page decides what an unreachable marketplace looks like.
Future<Uint8List?> fetchMarketplaceEntryFile(
  http.Client client,
  CompletionKind kind,
  String slug,
  String file,
) =>
    _get(client, Uri.parse("$marketplaceBaseUrl/${kind.folder}/$slug/$file"));

/// A skill's installable whole, the `.skill` the build writes beside the
/// entry's directory — `/skills/<slug>.skill` — rather than inside it, where
/// what `data/skills/<slug>/` is remains served file by file for reading.
/// The path shape is this function's, not a file name the caller spells;
/// the answer reads like [fetchMarketplaceEntryFile].
Future<Uint8List?> fetchMarketplaceSkillPackage(
  http.Client client,
  CompletionKind kind,
  String slug,
) =>
    _get(client, Uri.parse("$marketplaceBaseUrl/${kind.folder}/$slug.skill"));

Future<Uint8List?> _get(http.Client client, Uri uri) async {
  final response = await client.get(uri);
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw http.ClientException("HTTP ${response.statusCode}", uri);
  }
  return response.bodyBytes;
}