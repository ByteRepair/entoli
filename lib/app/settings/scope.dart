import "../../domain/settings/setting.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../providers.dart";
import "spec.dart";

/// Which level a controller is bound to, as a value: what a controller's
/// provider is keyed by, and what a frontend names when it asks for one.
sealed class ScopeAddress {
  const ScopeAddress();
}

final class AppAddress extends ScopeAddress {
  const AppAddress();

  @override
  bool operator ==(Object other) => other is AppAddress;

  @override
  int get hashCode => (AppAddress).hashCode;
}

final class ProjectAddress extends ScopeAddress {
  const ProjectAddress(this.project, {this.device});

  /// Null is the default project.
  final String? project;

  /// The paired device the project is on, null for this one: its settings
  /// are that device's, and so is the app's level above them.
  final String? device;

  ProjectRef get ref => (device: device, project: project);

  @override
  bool operator ==(Object other) =>
      other is ProjectAddress &&
      other.project == project &&
      other.device == device;

  @override
  int get hashCode => Object.hash(ProjectAddress, project, device);
}

/// The object that reads and writes a level's values: a controller asks it
/// what is set here, what would be inherited from above, and writes through
/// it. A level reads only its own document; what it inherits is its
/// [parent]'s answer.
sealed class SettingsScope {
  SettingsScope get root;

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
  Future<void> write<T extends Object>(Setting<T> setting, T? value) =>
      writeAll({setting: value});

  /// Sets each of [values] here in one write, so a pair is never half
  /// written.
  Future<void> writeAll(Map<Setting, Object?> values);
}

/// The app's `settings.json`, the top of every chain.
final class AppScope extends SettingsScope {
  AppScope(this._document, this._notifier);

  final SettingsDocument _document;
  final AppSettingsNotifier _notifier;

  @override
  SettingsScope get root => this;

  @override
  SettingsScope? get parent => null;

  @override
  SettingsDocument get document => _document;

  @override
  Future<void> writeAll(Map<Setting, Object?> values) =>
      _notifier.putAll(values);
}

/// A project's `project.json`, over the app's. What only projects and chats
/// hold — the sandbox, the rules — a project other than the default inherits
/// from the default project's, the tier every other project builds on.
final class ProjectScope extends SettingsScope {
  ProjectScope(
    this.project,
    this._document,
    this._notifier,
    this._parent, {
    this.base,
  });

  final String? project;
  final SettingsDocument _document;
  final ProjectSettingsNotifier _notifier;
  final AppScope _parent;

  /// The default project's, for a project that is not it.
  final ProjectScope? base;

  @override
  T? inherited<T extends Object>(Setting<T> setting) {
    if (!setting.scopes.contains(SettingScope.app)) {
      return base?.own(setting) ??
          (setting is DefaultedSetting<T> ? setting.fallback : null);
    }
    return super.inherited(setting);
  }

  @override
  SettingsScope get root => _parent;

  @override
  AppScope get parent => _parent;

  @override
  SettingsDocument get document => _document;

  @override
  Future<void> writeAll(Map<Setting, Object?> values) =>
      _notifier.putAll(values);
}

/// A chat's `meta.json` as it is being edited: written here as the page
/// changes it, and saved whole by the page's Save. The project it is in is
/// above it.
final class ChatScope extends SettingsScope {
  ChatScope(this._document, this._parent, {required this.onChange});

  final SettingsDocument _document;
  final ProjectScope _parent;

  /// Told after each change, so the page draws what is now held.
  final void Function() onChange;

  @override
  SettingsScope get root => _parent.root;

  @override
  ProjectScope get parent => _parent;

  @override
  SettingsDocument get document => _document;

  @override
  Future<void> writeAll(Map<Setting, Object?> values) {
    _document.setAll(values);
    onChange();
    return Future.value();
  }
}

/// The scope at [address], read through [reader], which is rebuilt whenever
/// its documents change.
SettingsScope scopeAt(SettingReader reader, ScopeAddress address) =>
    switch (address) {
      AppAddress() => AppScope(
        reader.watch(appSettingsProvider).doc,
        reader.read(appSettingsProvider.notifier),
      ),
      final ProjectAddress at => projectScopeAt(reader, at),
    };

/// [at]'s scope, the app's above it on whichever device it is.
ProjectScope projectScopeAt(SettingReader reader, ProjectAddress at) {
  final app = AppScope(
    reader.watch(appSettingsOf(at.ref)).doc,
    reader.read(appSettingsProvider.notifier),
  );
  ProjectScope of(String? project, {ProjectScope? base}) {
    final provider = projectSettingsOf((device: at.device, project: project));
    return ProjectScope(
      project,
      reader.watch(provider).doc,
      reader.read(provider.notifier),
      app,
      base: base,
    );
  }

  final project = at.project;
  return project == null ? of(null) : of(project, base: of(null));
}
