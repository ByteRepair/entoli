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

  void detach(Commands Function() read) {
    if (identical(_read, read)) _read = null;
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

/// One [AppCommand] as an action Shortcuts can name: `command.<name>`, the
/// enum's name being the id it is never renamed from.
final class CommandIntent implements IntentAction {
  const CommandIntent(this.command, this.scope);

  /// Every command, over [scope].
  static List<IntentAction> all(CommandScope scope) => [
    CommandListAction(),
    for (final command in AppCommand.values) CommandIntent(command, scope),
  ];

  final AppCommand command;
  final CommandScope scope;

  @override
  String get id => "command.${command.name}";

  @override
  Future<Object?> perform(IntentArgs args) async {
    if ((await scope.current()).run(command) case final Unavailable why) {
      throw IntentRefused.of(why);
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
    for (final command in AppCommand.values)
      {"id": command.name, "label": command.label.replaceAll("…", "")},
  ];
}
