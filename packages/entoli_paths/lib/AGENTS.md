# Where the app's data lives

`entoli_paths` answers where this platform keeps the app's data directory and
its cache. `appDirectories(home:)` is the whole of what the app reaches; it is
built once in `lib/core/platform/host.dart`, whose `dataDir()` and
`cacheDir()` put `$ENTOLI_CONFIG` and `$ENTOLI_CACHE` over its answers. Each
answer is resolved once per process.

| | Data | Cache |
| --- | --- | --- |
| Linux | `~/.config/entoli` | `$XDG_CACHE_HOME/entoli`, else `~/.cache/entoli` |
| macOS | `~/.config/entoli` | `~/Library/Caches/entoli` |
| Windows | `~/.config/entoli` | `%LOCALAPPDATA%\entoli\Cache` |
| Android | the app's documents directory | the support directory's `entoli` |
| iOS | the App Group container | the support directory's `entoli` |

A desktop debug build's leaf is `entoli-debug`, so it never touches an
installed copy's data. The home directory is handed in, being the local
shell's answer (`LocalShell.machineHomeDir`), so the shell and these paths
cannot disagree on it.

`path_provider` is the plugin under the phones' answers, and
`path_provider_foundation` asks for the App Group's container, which
`path_provider` does not. Where the container has no `entoli` yet,
`relocateDataDir` (`migrations.dart`) moves a `Documents/entoli` into it; see
"The workspaces in the Files app" in `ios/AGENTS.md`. `iosAppGroup` names the
group, which the File Provider extension spells out again in Swift.

The phones' cache is Application Support rather than a cache directory: both
systems empty that under storage pressure, and a model the user chose to
download is not something to lose that way. iOS backs Application Support up,
so the cache is flagged out of backups through CoreFoundation's URL resource
key (`backup_exclusion.dart`).
