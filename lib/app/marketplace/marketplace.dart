import "dart:convert";
import "dart:typed_data";

import "package:http/http.dart" as http;

import "../../data/prompts/skill_import.dart" show SkillPackage;
import "../../data/prompts/skill_package.dart";
import "../../domain/models.dart";

/// What the marketplace site lives at. A const until there is a reason to
/// move it; the section path is [CompletionKind.folder], the site's own.
const marketplaceBaseUrl = "https://byterepair.github.io/entoli-marketplace";

/// Where a remote entry's files live. The site's ext index records it for
/// every entry the site does not serve itself: the source repository, the ref
/// its publish resolved (null is the default branch, which raw content serves
/// as "HEAD"), the entry directory's full path in that repository, and every
/// blob under it — the file set, resolved by the site's build rather than
/// derived here.
class MarketplaceLocation {
  const MarketplaceLocation({
    required this.repo,
    required this.ref,
    required this.dir,
    required this.files,
  });

  final String repo;
  final String? ref;
  final String dir;
  final List<String> files;

  /// One of [files] at the published ref. "HEAD" reads the default branch,
  /// which is also how an unpinned ref is meant to drift.
  Uri file(String name) => Uri.parse(
    "https://raw.githubusercontent.com/$repo/${ref ?? "HEAD"}/$dir/$name",
  );

  /// The entry's directory on GitHub, for a person to read.
  Uri get page =>
      Uri.parse("https://github.com/$repo/tree/${ref ?? "HEAD"}/$dir");

  /// Strict: [fetchMarketplaceEntries] throws on anything it cannot read, so
  /// an ext record missing a piece is an unreachable marketplace rather than
  /// an entry that half-works.
  factory MarketplaceLocation.fromJson(String key, Map<String, Object?> json) {
    final repo = json["repo"];
    final ref = json["ref"];
    final dir = json["dir"];
    final files = json["files"];
    if (repo is! String || repo.isEmpty) {
      throw FormatException("ext entry $key: no repository recorded");
    }
    if (ref != null && ref is! String) {
      throw FormatException("ext entry $key: ref is not a string");
    }
    if (dir is! String || dir.isEmpty) {
      throw FormatException("ext entry $key: no directory recorded");
    }
    if (files is! List || files.any((file) => file is! String)) {
      throw FormatException("ext entry $key: no file list recorded");
    }
    return MarketplaceLocation(
      repo: repo,
      ref: ref as String?,
      dir: dir,
      files: List.unmodifiable(files.cast<String>()),
    );
  }
}

/// One entry of the marketplace, as an `index.json` names it. The fields are
/// the site's; `version` and `tags` are there only when the entry's
/// frontmatter set them. [location] is present only on an entry the site does
/// not serve itself — a remote one, whose files are fetched from its source
/// repository.
///
/// No const constructor: the search's lowercased forms are `late final` on
/// the entry, and a generative const constructor cannot have them.
class MarketplaceEntry {
  MarketplaceEntry({
    required this.slug,
    required this.name,
    required this.description,
    required this.author,
    this.version,
    this.tags = const [],
    this.location,
  });

  final String slug;
  final String name;
  final String description;
  final String author;
  final String? version;
  final List<String> tags;
  final MarketplaceLocation? location;

  /// Whether its files are another repository's rather than the site's.
  bool get external => location != null;

  /// Its authors, as the site joins them: a remote entry's are its source's
  /// contributors, up to ten.
  late final List<String> authors = [
    for (final name in author.split(","))
      if (name.trim() case final name when name.isNotEmpty) name,
  ];

  /// Who made it, short enough for a row: the first author, and how many
  /// more.
  String? get byline => switch (authors) {
    [] => null,
    [final one] => "by $one",
    [final first, ...final rest] => "by $first and ${rest.length} more",
  };

  /// The name an agent installs under: the slug's last segment — an ext key
  /// carries its manifest's name ahead of the entry's own, and the
  /// marketplace names an agent after its remote directory. A skill's
  /// installed name is its frontmatter's, so this is read only of agents.
  String get installName => slug.split("/").last;

  /// What the search matches against, lowercased once per entry — computed
  /// off the first search pass rather than off every keystroke's.
  late final String lowerName = name.toLowerCase();
  late final String lowerDescription = description.toLowerCase();

  factory MarketplaceEntry.fromJson(
    String slug,
    Map<String, Object?> json, {
    MarketplaceLocation? location,
  }) => MarketplaceEntry(
    slug: slug,
    name: (json["name"] as String?) ?? slug,
    description: (json["description"] as String?) ?? "",
    author: (json["author"] as String?) ?? "",
    version: json["version"] as String?,
    tags: (json["tags"] as List<Object?>?)?.cast<String>() ?? const [],
    location: location,
  );
}

/// What `<folder>/collections.json` says of one collection: the name and
/// summary its members are shown under, and the members by index key.
typedef CollectionRecord = ({
  String name,
  String summary,
  List<String> members,
});

/// A section as the site lists it: every entry, and the collection records
/// that group the remote ones (see `groupIntoCollections`).
class MarketplaceListing {
  const MarketplaceListing(this.entries, [this.collections = const {}]);

  final List<MarketplaceEntry> entries;
  final Map<String, CollectionRecord> collections;
}

/// The marketplace's list for [kind]: the site's section index, joined where
/// it names one with the ext index's location record, and the collection
/// records beside them. Throws on anything it cannot read, so the page
/// decides what an unreachable marketplace looks like. An ext index or a
/// collections file that is not there (a site published before either) reads
/// as none; any other bad answer throws.
Future<MarketplaceListing> fetchMarketplaceEntries(
  http.Client client,
  CompletionKind kind,
) async {
  final index = Uri.parse("$marketplaceBaseUrl/${kind.folder}/index.json");
  final (body, locations, collections) = await (
    _get(client, index),
    _fetchLocations(client, kind),
    _fetchCollections(client, kind),
  ).wait;
  // A missing index is a site that cannot be read, not an empty one.
  if (body == null) throw http.ClientException("HTTP 404", index);
  final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
  final entries = [
    for (final MapEntry(:key, :value) in json.entries)
      MarketplaceEntry.fromJson(
        key,
        value as Map<String, Object?>,
        location: locations[key],
      ),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return MarketplaceListing(entries, collections);
}

Future<Map<String, CollectionRecord>> _fetchCollections(
  http.Client client,
  CompletionKind kind,
) async {
  final uri = Uri.parse("$marketplaceBaseUrl/${kind.folder}/collections.json");
  final body = await _get(client, uri);
  if (body == null) return const {};
  final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
  return {
    for (final MapEntry(:key, :value) in json.entries)
      key: _collectionRecord(key, value as Map<String, Object?>),
  };
}

CollectionRecord _collectionRecord(String slug, Map<String, Object?> json) => (
  name: (json["name"] as String?) ?? slug,
  summary: (json["summary"] as String?) ?? "",
  members: (json["members"] as List<Object?>?)?.cast<String>() ?? const [],
);

/// The site's ext index: where each remote entry's files live, keyed as the
/// section index keys them. The build writes it per entry; a site older than
/// remote entries publishes none, which reads as no locations at all.
Future<Map<String, MarketplaceLocation>> _fetchLocations(
  http.Client client,
  CompletionKind kind,
) async {
  final body = await _get(
    client,
    Uri.parse("$marketplaceBaseUrl/ext/${kind.folder}/index.json"),
  );
  if (body == null) return const {};
  final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
  return {
    for (final MapEntry(:key, :value) in json.entries)
      key: MarketplaceLocation.fromJson(key, value as Map<String, Object?>),
  };
}

/// One file of one entry: `README.md`, `PROMPT.md`, `profile.png`. A local
/// entry fetches it from the site; a remote one from its source repository,
/// where a file the location record does not list is answered without a
/// request. Null is a 404 — a file the entry does not carry (a picture, most
/// often), which is an answer rather than a failure; anything else that goes
/// wrong throws, so the page decides what an unreachable marketplace looks
/// like.
Future<Uint8List?> fetchMarketplaceEntryFile(
  http.Client client,
  CompletionKind kind,
  MarketplaceEntry entry,
  String file,
) {
  final location = entry.location;
  if (location != null) {
    if (!location.files.contains(file)) return Future.value();
    return _get(client, location.file(file));
  }
  return _get(
    client,
    Uri.parse("$marketplaceBaseUrl/${kind.folder}/${entry.slug}/$file"),
  );
}

/// A remote entry's listing disagrees with its source: a file the listing
/// names is gone from the repository. An installable page with nothing to
/// install — the reason goes where the button would be, not to the failure
/// pane.
class MarketplacePackageProblem implements Exception {
  const MarketplacePackageProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A skill's installable whole. A local entry fetches the `.skill` the build
/// writes beside its directory; a remote one is served no file — its listed
/// ones are fetched from the source repository and zipped here, the way the
/// site packages a directory, so the same intake parses both. Null is a local
/// entry served no package; [MarketplacePackageProblem] is a remote one whose
/// listing has drifted from what the repository serves. The answer reads like
/// [fetchMarketplaceEntryFile].
Future<Uint8List?> fetchMarketplaceSkillPackage(
  http.Client client,
  CompletionKind kind,
  MarketplaceEntry entry,
) async {
  final location = entry.location;
  if (location == null) {
    return _get(
      client,
      Uri.parse("$marketplaceBaseUrl/${kind.folder}/${entry.slug}.skill"),
    );
  }
  final bodies = await Future.wait([
    for (final file in location.files) _get(client, location.file(file)),
  ]);
  final entries = <(String, Uint8List)>[];
  for (var i = 0; i < location.files.length; i++) {
    final data = bodies[i];
    if (data == null) {
      throw MarketplacePackageProblem(
        "The listing is stale against the source: ${location.files[i]} was "
        "not there to fetch from ${location.repo}.",
      );
    }
    entries.add((location.files[i], data));
  }
  // The files were listed by the build against the same commit it published
  // from, so the assembled whole is the source's directory, zipped flat —
  // named after the entry here for nothing but the package's constructor.
  return packageSkillBytes(SkillPackage(entry.slug, entries));
}

Future<Uint8List?> _get(http.Client client, Uri uri) async {
  final response = await client.get(uri);
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw http.ClientException("HTTP ${response.statusCode}", uri);
  }
  return response.bodyBytes;
}
