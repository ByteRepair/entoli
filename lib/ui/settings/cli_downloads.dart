import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/providers/presets.dart" show CliProvider;
import "downloads.dart";

/// The CLI programs' half of [Downloads]: each one fetched into Entoli's own
/// copy of it, in the cache beside where its sessions run.
class CliDownloads extends Downloads<CliProvider> {
  @override
  String idOf(CliProvider cli) => cli.workFolder;

  /// Nothing where the platform runs no programs.
  @override
  Download? begin(CliProvider cli) =>
      cli.supported ? Download(bytes: 0, progress: cli.install()) : null;

  @override
  String nameOf(CliProvider cli) => cli.config.displayName;

  @override
  String get plural => "programs";

  /// Nothing to read again: whether a copy is there is [CliProvider.installed],
  /// asked of the disk each time.
  @override
  Future<void> rescan() async {}

  /// Nothing to let go of: a provider on the program finds whatever other
  /// copy there is, and says so where there is none.
  @override
  Future<void> unpick(CliProvider cli) async {}

  @override
  Future<void> erase(CliProvider cli) => cli.uninstall();
}

final cliDownloadsProvider = NotifierProvider<CliDownloads, DownloadState>(
  CliDownloads.new,
);
