import "package:entoli_core/model/settings/setting.dart";
import "package:entoli_core/model/project.dart" show ProjectRef;
import "package:entoli_core/transcript/reader.dart";

import "../../providers.dart";

/// Which level a setting is read and written at, as a value: what a page
/// names when it asks for a scope.
sealed class ScopeAddress {
  const ScopeAddress();
}

final class AppAddress extends ScopeAddress {
  const AppAddress();
}

final class ProjectAddress extends ScopeAddress {
  const ProjectAddress(this.project, {this.device});

  /// Null is the default project.
  final String? project;

  /// The paired device the project is on, null for this one: its settings
  /// are that device's, and so is the app's level above them.
  final String? device;

  ProjectRef get ref => (device: device, project: project);
}

/// A chat's settings as its page holds them until Save: [document] is the
/// draft's `meta.json`, [project]'s level above it, and [onChange] is told of
/// each change written to it.
final class ChatAddress extends ScopeAddress {
  const ChatAddress(this.document, {this.project, required this.onChange});

  final SettingsDocument document;
  final String? project;
  final void Function() onChange;
}

/// The object that reads and writes a level's values: what is set here,
/// what would be inherited from above, and the write. A level reads only
/// its own document; what it inherits is its [parent]'s answer.
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

  /// Whether unset is offered for [setting] here: where the level inherits —
  /// a project, a chat — or where the key has no fallback even at the app's.
  /// A control then stands where the level above does, with a reset back to
  /// it once this level picks.
  bool offersUnset(Setting setting) =>
      parent != null || setting is! DefaultedSetting;

  /// What a control over [setting] shows: this level's own value where
  /// unset is offered, else what it answers.
  T? shown<T extends Object>(Setting<T> setting) =>
      offersUnset(setting) ? own(setting) : resolve(setting);

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
    this.device,
  });

  final String? project;

  /// The paired device the project is on, null for this one.
  final String? device;
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
      final ChatAddress at => ChatScope(
        at.document,
        projectScopeAt(reader, ProjectAddress(at.project)),
        onChange: at.onChange,
      ),
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
      device: at.device,
    );
  }

  final project = at.project;
  return project == null ? of(null) : of(project, base: of(null));
}
