import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/availability.dart";
import "../domain/intent_action.dart";
import "app_command.dart";
import "commands.dart";

/// Where an action from outside reaches [Commands]: the chat pane's, once
/// there is one. A command acts on what the pane shows, so it needs the
/// pane's context, which exists only while `AppShell` is mounted — and an
/// action can arrive before that, on a launch the action itself started.
class CommandScope {
  Commands Function()? _read;
  Completer<void>? _attached;

  /// [read] takes a snapshot of the pane as it is when called.
  void attach(Commands Function() read) {
    _read = read;
    _attached?.complete();
    _attached = null;
  }

  /// Equality rather than identity: a method torn off twice is two equal
  /// closures, never one identical one.
  void detach(Commands Function() read) {
    if (_read == read) _read = null;
  }

  /// The pane's commands as they are now, waiting a while for a pane that
  /// is still being built.
  Future<Commands> current() async {
    if (_read == null) {
      final attached = _attached ??= Completer<void>();
      await attached.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw const IntentRefused("Entoli is not showing its window."),
      );
    }
    return _read!();
  }
}

final commandScopeProvider = Provider<CommandScope>((ref) => CommandScope());

/// One [AppItem] as an action Shortcuts can name: `command.<id>`, the
/// enum's name being the id it is never renamed from.
final class CommandIntent implements IntentAction {
  const CommandIntent(this.command, this.scope);

  /// Every command, over [scope].
  static List<IntentAction> all(CommandScope scope) => [
    CommandListAction(),
    for (final command in appItems) CommandIntent(command, scope),
  ];

  final AppItem command;
  final CommandScope scope;

  @override
  String get id => "command.${command.id}";

  @override
  Future<Object?> perform(IntentArgs args) async {
    if ((await scope.current()).run(command) case final Unavailable why) {
      throw IntentRefused(why.reason);
    }
    return null;
  }
}

/// The commands there are, for Shortcuts to offer: each one's id and label.
/// Asked of the app rather than written into the Swift, so a command added
/// here is offered there with nothing else changed.
final class CommandListAction implements IntentAction {
  @override
  String get id => "commands";

  @override
  Future<Object?> perform(IntentArgs args) async => [
    for (final command in appItems)
      {"id": command.id, "label": command.title.replaceAll("…", "")},
  ];
}
