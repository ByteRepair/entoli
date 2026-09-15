import "package:fs_shim/fs.dart";

import "../domain/documents.dart";
import "config.dart";

/// A change to the data directory that a release makes once, to files an
/// earlier release wrote. See "Migrations" in CLAUDE.md for writing one.
class Migration {
  const Migration(this.version, this.apply);

  /// The release this shipped in. A name rather than a number to compare: what
  /// runs is decided by where the entry sits in [migrations].
  final String version;

  /// A filesystem and a data directory rather than the `AppConfig` over them:
  /// an entry describes a layout that no longer exists, and a path helper
  /// answers for the one this build has.
  final Future<void> Function(FileSystem fs, String dataDir) apply;
}

/// The chain, oldest first: each entry moves what the one above it left, and
/// nothing older. Empty until a release changes the layout.
const List<Migration> migrations = [];

/// Bring [config]'s data directory to the end of [chain]. Called at launch and
/// again after a restore, since a backup unpacks the layout of the build that
/// made it, stamp and all.
///
/// [fresh] is a data directory this launch created, which is stamped and left
/// alone: without that the next release's entry would run over files that were
/// never in the shape it moves from.
///
/// [chain] is a parameter so a test can drive the engine with entries of its
/// own.
Future<void> runMigrations(AppConfig config,
    {required bool fresh, List<Migration> chain = migrations}) async {
  if (chain.isEmpty) return;
  if (fresh) return _stamp(config, chain.last);
  for (final migration in await _pending(config, chain)) {
    await migration.apply(config.fs, config.dataDir);
    // As each one goes rather than at the end: a run cut short by a kill picks
    // up at the entry it died in.
    await _stamp(config, migration);
  }
}

/// Nothing, where the stamp names no entry this build has — the directory was
/// written by a newer build, and moving its files to an older idea of the
/// layout is worse than leaving them where they are. No stamp at all is a
/// directory older than every entry there is.
Future<List<Migration>> _pending(AppConfig config, List<Migration> chain) async {
  final file = config.fs.file(config.versionFile);
  if (!await file.exists()) return chain;
  final stamped = (await file.readAsString()).trim();
  final at = chain.indexWhere((migration) => migration.version == stamped);
  return at < 0 ? const [] : chain.sublist(at + 1);
}

/// Through a rename, the way every other small file here is written: a
/// `writeAsString` killed between its truncate and its write leaves a stamp
/// naming no entry, and that directory is frozen out of every migration to
/// come.
Future<void> _stamp(AppConfig config, Migration migration) =>
    writeThroughRename(config.fs, config.versionFile, migration.version);
