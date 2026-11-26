import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/llm_provider.dart";
import "package:entoli_core/model/profile.dart";
import "package:entoli_core/model/sync/settings_merge.dart";

import "../data/sync/sync_hub.dart";
import "../providers.dart";

/// This device's profile and providers as [SettingsSync] reads and writes
/// them: the settings notifier for both, the secret store for each
/// provider's key. Read once for its effect, like `RemoteTurnDriver`: it
/// binds itself to the hub and tells it of every change.
class SettingsSyncDriver implements SyncedSettings {
  SettingsSyncDriver(this._ref, this._sync) {
    _sync.settings = this;
    _watch = _ref.listen<AppSettings>(appSettingsProvider, (before, now) {
      if (before?.profile != now.profile ||
          !identical(before?.llmProviders, now.llmProviders)) {
        _sync.changed();
      }
    });
  }

  final Ref _ref;
  final SettingsSync _sync;
  late final ProviderSubscription<AppSettings> _watch;

  /// A CLI's program and environment are this machine's: a path on one is
  /// nothing on another, so they stay where they were set.
  static const _machineFields = {"id", "command", "env"};

  @override
  SyncedItems read() {
    final settings = _ref.read(appSettingsProvider);
    final secrets = _ref.read(appSecretsProvider);
    return {
      if (settings.profile case final profile? when !profile.isEmpty)
        profileItem: profile.toJson(),
      for (final provider in settings.llmProviders)
        providerItem(provider.id): {
          for (final MapEntry(:key, :value) in provider.toJson().entries)
            if (!_machineFields.contains(key)) key: value,
          "key": ?secrets.providerKey(provider.id),
        },
    };
  }

  @override
  Future<void> write(SyncedItems items) async {
    final notifier = _ref.read(appSettingsProvider.notifier);
    final settings = _ref.read(appSettingsProvider);
    final secrets = _ref.read(appSecretsProvider);
    final profile = Profile.fromJson(items[profileItem]);
    if (profile != settings.profile) {
      await notifier.setReplyStyle(profile: profile);
    }
    final local = {for (final p in settings.llmProviders) p.id: p};
    LlmProviderConfig? configOf(String id, Map<String, Object?> fields) {
      final here = local[id];
      return LlmProviderConfig.fromJson({
        ...fields,
        "id": id,
        "command": ?here?.command,
        if (here != null && here.env.isNotEmpty) "env": here.env,
      });
    }

    final incoming = <String, (LlmProviderConfig, String?)>{
      for (final MapEntry(:key, :value) in items.entries)
        if ((providerIdOf(key), value) case (final id?, final fields?))
          if (configOf(id, fields) case final config?)
            id: (config, fields["key"] as String?),
    };
    // Keys first: the list's rebuild reads the store.
    for (final MapEntry(key: id, value: (_, key)) in incoming.entries) {
      await secrets.setProviderKey(id, key);
    }
    await notifier.setProviders([
      // In the order this device had them, then the new ones.
      for (final id in local.keys)
        if (incoming[id] case (final config, _)) config,
      for (final MapEntry(key: id, value: (config, _)) in incoming.entries)
        if (!local.containsKey(id)) config,
    ]);
  }

  void dispose() => _watch.close();
}

/// The hub's [SettingsSync], where the app has a hub: `main` binds it, and
/// a shell without one asks nothing.
final settingsSyncProvider = Provider<SettingsSync?>((ref) => null);

final settingsSyncDriverProvider = Provider<SettingsSyncDriver>((ref) {
  final driver = SettingsSyncDriver(
    ref,
    ref.watch(syncHubProvider).settingsSync,
  );
  ref.onDispose(driver.dispose);
  return driver;
});
