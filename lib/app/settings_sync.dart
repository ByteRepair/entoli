import "package:collection/collection.dart";
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
/// binds itself to the hub and tells it of every change but its own.
class SettingsSyncDriver implements SyncedSettings {
  SettingsSyncDriver(this._ref, this._sync) {
    _sync.settings = this;
    _watch = _ref.listen<AppSettings>(appSettingsProvider, (before, now) {
      if (_writing) return;
      if (before?.profile != now.profile ||
          !identical(before?.llmProviders, now.llmProviders)) {
        _sync.changed();
      }
    });
  }

  final Ref _ref;
  final SettingsSync _sync;
  late final ProviderSubscription<AppSettings> _watch;

  /// A merge landing, which the peer it came from already holds.
  var _writing = false;

  @override
  SyncedItems read() {
    final settings = _ref.read(appSettingsProvider);
    final providers = settings.llmProviders;
    final keys = _ref
        .read(appSecretsProvider)
        .providerKeys(providers.map((p) => p.id));
    return {
      if (settings.profile case final profile? when !profile.isEmpty)
        profileItem: profile.toJson(),
      for (final provider in providers)
        providerItem(provider.id): {
          ...provider.toPortableJson(),
          "key": ?keys[provider.id],
        },
    };
  }

  @override
  Future<void> write(SyncedItems items) async {
    _writing = true;
    try {
      await _write(items);
    } finally {
      _writing = false;
    }
  }

  Future<void> _write(SyncedItems items) async {
    final notifier = _ref.read(appSettingsProvider.notifier);
    final settings = _ref.read(appSettingsProvider);
    final profile = Profile.fromJson(items[profileItem]);
    if (profile != settings.profile) {
      await notifier.setReplyStyle(profile: profile);
    }
    final local = {for (final p in settings.llmProviders) p.id: p};
    final incoming = <String, (LlmProviderConfig, String?)>{
      for (final MapEntry(:key, :value) in items.entries)
        if (providerIdOf(key) case final id?)
          if (LlmProviderConfig.fromPortable(id, value, here: local[id])
              case final config?)
            id: (config, value["key"] as String?),
    };
    // Keys first: the list's rebuild reads the store.
    await _ref.read(appSecretsProvider).setProviderKeys({
      for (final MapEntry(key: id, value: (_, key)) in incoming.entries)
        id: key,
    });
    final providers = [
      // In the order this device had them, then the new ones.
      for (final id in local.keys)
        if (incoming[id] case (final config, _)) config,
      for (final MapEntry(key: id, value: (config, _)) in incoming.entries)
        if (!local.containsKey(id)) config,
    ];
    // A list set again rebuilds every model list, so only where it moved.
    if (!const DeepCollectionEquality().equals(
      [for (final p in providers) p.toJson()],
      [for (final p in settings.llmProviders) p.toJson()],
    )) {
      await notifier.setProviders(providers);
    }
  }

  void dispose() {
    _watch.close();
    if (identical(_sync.settings, this)) _sync.settings = null;
  }
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
