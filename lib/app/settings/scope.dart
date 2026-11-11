import "../../domain/settings/setting.dart";
import "../../providers.dart";
import "spec.dart";

/// Which level a controller is bound to, as a value: what a controller's
/// provider is keyed by, and what a frontend names when it asks for one.
sealed class ScopeAddress {
  const ScopeAddress();

  SettingScope get level;
}

final class AppAddress extends ScopeAddress {
  const AppAddress();

  @override
  SettingScope get level => SettingScope.app;

  @override
  bool operator ==(Object other) => other is AppAddress;

  @override
  int get hashCode => (AppAddress).hashCode;
}

final class ProjectAddress extends ScopeAddress {
  const ProjectAddress(this.project);

  /// Null is the default project.
  final String? project;

  @override
  SettingScope get level => SettingScope.project;

  @override
  bool operator ==(Object other) =>
      other is ProjectAddress && other.project == project;

  @override
  int get hashCode => Object.hash(ProjectAddress, project);
}

/// The object that reads and writes a level's values: a controller asks it
/// what is set here, what would be inherited from above, and writes through
/// it. A level reads only its own document; what it inherits is its
/// [parent]'s answer.
sealed class SettingsScope {
  SettingsScope get root;

  SettingScope get level;

  SettingsScope? get parent;

  SettingsDocument get document;

  /// What this level holds, or null where it holds nothing.
  T? own<T extends Object>(Setting<T> setting) => document.read(setting);

  /// What this level would take from those above it.
  T? inherited<T extends Object>(Setting<T> setting) {
    final above = parent;
    if (above != null) return above.resolve(setting);
    return setting is DefaultedSetting<T> ? setting.fallback : null;
  }

  /// What this level answers: its own value, or what it inherits.
  T? resolve<T extends Object>(Setting<T> setting) =>
      own(setting) ?? inherited(setting);

  /// Sets [setting] here, or clears it where [value] is null.
  Future<void> write<T extends Object>(Setting<T> setting, T? value);

  /// Sets each of [values] here in one write, so a pair is never half
  /// written.
  Future<void> writeAll(Map<Setting, Object?> values);

  /// Whether this level may hold [setting] at all.
  bool holds(Setting setting) => setting.scopes.contains(level);
}

/// The app's `settings.json`, the top of every chain.
final class AppScope extends SettingsScope {
  AppScope(this._document, this._notifier);

  final SettingsDocument _document;
  final AppSettingsNotifier _notifier;

  @override
  SettingsScope get root => this;

  @override
  SettingScope get level => SettingScope.app;

  @override
  SettingsScope? get parent => null;

  @override
  SettingsDocument get document => _document;

  @override
  Future<void> write<T extends Object>(Setting<T> setting, T? value) =>
      _notifier.put(setting, value);

  @override
  Future<void> writeAll(Map<Setting, Object?> values) =>
      _notifier.putAll(values);

  /// The notifier, for a value whose setter has more to do than write it.
  AppSettingsNotifier get notifier => _notifier;
}

/// A project's `project.json`, over the app's.
final class ProjectScope extends SettingsScope {
  ProjectScope(this.project, this._document, this._notifier, this._parent);

  final String? project;
  final SettingsDocument _document;
  final ProjectSettingsNotifier _notifier;
  final AppScope _parent;

  @override
  SettingsScope get root => _parent;

  @override
  SettingScope get level => SettingScope.project;

  @override
  AppScope get parent => _parent;

  @override
  SettingsDocument get document => _document;

  @override
  Future<void> write<T extends Object>(Setting<T> setting, T? value) =>
      _notifier.put(setting, value);

  @override
  Future<void> writeAll(Map<Setting, Object?> values) =>
      _notifier.putAll(values);
}

/// The scope at [address], read through [reader], which is rebuilt whenever
/// its documents change.
SettingsScope scopeAt(SettingReader reader, ScopeAddress address) {
  final app = AppScope(
    reader.watch(appSettingsProvider).doc,
    reader.read(appSettingsProvider.notifier),
  );
  return switch (address) {
    AppAddress() => app,
    ProjectAddress(:final project) => ProjectScope(
      project,
      reader.watch(projectSettingsProvider(project)).doc,
      reader.read(projectSettingsProvider(project).notifier),
      app,
    ),
  };
}
