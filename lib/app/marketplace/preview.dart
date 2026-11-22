import "dart:convert";
import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:http/http.dart" as http;

import "../../core/log.dart";
import "../../data/prompts/skill_import.dart";
import "../../domain/app_link.dart" show SharedEntryLink;
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../providers.dart";
import "marketplace.dart";

/// One section's list, fetched on first watch and fetched again on a reopen
/// rather than showing what may have changed underneath it. Riverpod's own
/// retry is off: the retry is the user's Try again, not ten rounds of
/// backoff they cannot see or stop.
final marketplaceEntriesProvider = FutureProvider.autoDispose
    .family<MarketplaceListing, CompletionKind>((ref, kind) async {
      final client = ref.watch(marketplaceClientProvider);
      try {
        return await fetchMarketplaceEntries(client, kind);
      } catch (e) {
        // Once, where it is caught, rather than on every redraw of the error.
        logFailure("marketplace", "could not fetch ${kind.label}", e);
        rethrow;
      }
    }, retry: (_, _) => null);

/// What a preview fetched at open: the README, the parsed `.skill` or why
/// the parser refused it, an agent's prompt and its picture. A null member
/// is a file the entry does not carry, which is an answer, not a failure.
class EntryPreview {
  const EntryPreview({
    this.package,
    this.packageProblem,
    this.prompt,
    this.promptSource,
    this.picture,
    this.readme,
  });

  final SkillPackage? package;

  /// Why there is nothing to install, shown where the button would be.
  final String? packageProblem;

  final PromptDocument? prompt;

  /// An agent's PROMPT.md as served, which is what is written.
  final String? promptSource;

  final Uint8List? picture;
  final String? readme;

  /// The one answer to whether Install is offered, which either install's
  /// refusal reads too.
  bool installable(CompletionKind kind) => switch (kind) {
    CompletionKind.skill => package != null,
    CompletionKind.agent =>
      promptSource != null && (prompt?.body.isNotEmpty ?? false),
  };
}

/// [entry]'s files, fetched together: each is a round trip to one host.
/// Throws where the site could not be read; a listing gone stale against its
/// source is a preview with nothing to install instead.
Future<EntryPreview> loadEntryPreview(
  http.Client client,
  CompletionKind kind,
  MarketplaceEntry entry,
) async {
  try {
    final [readme, body, picture] = await Future.wait(<Future<Uint8List?>>[
      fetchMarketplaceEntryFile(client, kind, entry, "README.md"),
      switch (kind) {
        CompletionKind.skill => fetchMarketplaceSkillPackage(
          client,
          kind,
          entry,
        ),
        CompletionKind.agent => fetchMarketplaceEntryFile(
          client,
          kind,
          entry,
          "PROMPT.md",
        ),
      },
      kind == CompletionKind.skill
          ? Future<Uint8List?>.value()
          : fetchMarketplaceEntryFile(client, kind, entry, "profile.png"),
    ]);
    SkillPackage? package;
    String? problem;
    String? source;
    if (kind == CompletionKind.skill) {
      if (body == null) {
        problem = "No installable package is served for this skill.";
      } else {
        try {
          package = parseSkillPackage(body);
        } catch (e) {
          problem = "$e";
        }
      }
    } else if (body != null) {
      source = utf8.decode(body, allowMalformed: true);
    }
    return EntryPreview(
      readme: readme == null ? null : utf8.decode(readme, allowMalformed: true),
      package: package,
      packageProblem: problem,
      promptSource: source,
      prompt: source == null
          ? null
          : PromptDocument.parse(CompletionKind.agent, "", source),
      picture: picture,
    );
  } on MarketplacePackageProblem catch (e) {
    logFailure("marketplace", "${entry.slug}'s listing is stale", e);
    return EntryPreview(packageProblem: "$e");
  } catch (e) {
    logFailure("marketplace", "could not fetch ${entry.slug}'s preview", e);
    rethrow;
  }
}

/// A link carrying an entry whole: the entry it names and its preview, with
/// nothing fetched. A link cut short on its way is said, with no Install.
(MarketplaceEntry, EntryPreview) sharedEntry(SharedEntryLink link) {
  final kind = link.kind;
  MarketplaceEntry entry(String name, String? description) => MarketplaceEntry(
    slug: name,
    name: name,
    description: description ?? "",
    author: "",
  );
  final shared = entry(link.name ?? "Shared ${kind.name}", null);
  final bytes = link.bytes;
  if (bytes == null) {
    return (
      shared,
      const EntryPreview(
        packageProblem:
            "This link is incomplete: it was cut short on its way here, so "
            "there is nothing to install. Ask for it again, or for the file.",
      ),
    );
  }
  switch (kind) {
    case CompletionKind.skill:
      try {
        final package = parseSkillPackage(bytes);
        return (
          entry(package.name, package.description),
          EntryPreview(package: package, readme: package.body),
        );
      } catch (e) {
        return (shared, EntryPreview(packageProblem: "$e"));
      }
    case CompletionKind.agent:
      final source = utf8.decode(bytes, allowMalformed: true);
      final prompt = PromptDocument.parse(kind, "", source);
      final name = link.name ?? prompt.frontmatter["name"];
      if (name == null) {
        return (
          shared,
          const EntryPreview(packageProblem: "The link names no agent."),
        );
      }
      return (
        entry(name, prompt.description),
        EntryPreview(prompt: prompt, promptSource: source, readme: prompt.body),
      );
  }
}
