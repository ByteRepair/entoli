import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/providers/presets.dart" show CliProvider;
import "../../providers.dart";
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

  @override
  Future<void> rescan() async =>
      ref.read(installedClisProvider.notifier).refresh();

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

/// Which of [cliProgramsProvider] Entoli has its own copy of, by
/// [CliProvider.workFolder]: read off the disk, and again whenever a
/// download lands or a copy is deleted.
class InstalledClis extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(cliProgramsProvider);
    return _scan();
  }

  void refresh() {
    final now = _scan();
    if (now.length != state.length || !now.containsAll(state)) state = now;
  }

  Set<String> _scan() => {
    for (final cli in ref.read(cliProgramsProvider))
      if (cli.installed) cli.workFolder,
  };
}

final installedClisProvider = NotifierProvider<InstalledClis, Set<String>>(
  InstalledClis.new,
);
