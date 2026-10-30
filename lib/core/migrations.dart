import "dart:io";

import "package:path/path.dart" as p;

import "../domain/documents.dart";

/// A change to the data directory that a release makes once, to files an
/// earlier release wrote. See "Migrations" in AGENTS.md for writing one.
class Migration {
  const Migration(this.version, this.apply);

  /// The release this shipped in. A name rather than a number to compare: what
  /// runs is decided by where the entry sits in [migrations].
  final String version;

  /// A filesystem and a data directory rather than the `AppConfig` over them:
  /// an entry describes a layout that no longer exists, and a path helper
  /// answers for the one this build has.
  final Future<void> Function(String dataDir) apply;
}

/// The stamp in [dataDir] naming the release whose entry last ran there.
/// Not the app's version: a release that leaves the layout alone leaves it
/// where it was.
String migrationStamp(String dataDir) =>
    p.join(dataDir, "version");

/// The chain, oldest first: each entry moves what the one above it left, and
/// nothing older. Empty until a release changes the layout.
const List<Migration> migrations = [];

/// Bring [dataDir] to the end of [chain]. Called at launch and
/// again after a restore, since a backup unpacks the layout of the build that
/// made it, stamp and all.
///
/// [fresh] is a data directory this launch created, which is stamped and left
/// alone: without that the next release's entry would run over files that were
/// never in the shape it moves from.
///
/// [chain] is a parameter so a test can drive the engine with entries of its
/// own.
Future<void> runMigrations(String dataDir,
    {required bool fresh, List<Migration> chain = migrations}) async {
  if (chain.isEmpty) return;
  if (fresh) return _stamp(dataDir, chain.last);
  for (final migration in await _pending(dataDir, chain)) {
    await migration.apply(dataDir);
    // As each one goes rather than at the end: a run cut short by a kill picks
    // up at the entry it died in.
    await _stamp(dataDir, migration);
  }
}

/// Nothing, where the stamp names no entry this build has — the directory was
/// written by a newer build, and moving its files to an older idea of the
/// layout is worse than leaving them where they are. No stamp at all is a
/// directory older than every entry there is.
Future<List<Migration>> _pending(
    String dataDir, List<Migration> chain) async {
  final file = File(migrationStamp(dataDir));
  if (!file.existsSync()) return chain;
  final stamped = (await file.readAsString()).trim();
  final at = chain.indexWhere((migration) => migration.version == stamped);
  return at < 0 ? const [] : chain.sublist(at + 1);
}

/// Through a rename, the way every other small file here is written: a
/// `writeAsString` killed between its truncate and its write leaves a stamp
/// naming no entry, and that directory is frozen out of every migration to
/// come.
Future<void> _stamp(String dataDir, Migration migration) =>
    writeThroughRename(migrationStamp(dataDir), migration.version);
