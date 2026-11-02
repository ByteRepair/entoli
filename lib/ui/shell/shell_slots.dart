import "package:flutter_riverpod/flutter_riverpod.dart";

/// The surfaces the native shell draws for a page, each answering the intents
/// sent under its name: `ShellModel.say` on the Swift side.
enum ShellConcern { composer, turn, newChatScreen, voice, toolbar }

/// One of them on a page: the composer, the turn surface, the new-chat
/// screen, voice mode, the chat's toolbar.
abstract interface class ShellSurface {
  /// What the shell sent it: [name] says what, [args] the rest. Answers what
  /// the Swift waits on, or null.
  Future<Object?> handle(String name, Map<String, Object?> args);
}

/// Where each concern's intents go: the surface on top of its stack, which is
/// the one on screen. Voice mode's turn surface is over the chat page's, and
/// when it goes the chat page's is on top again.
class ShellSlots {
  final Map<ShellConcern, List<ShellSurface>> _stacks = {};

  ShellSurface? top(ShellConcern concern) => _stacks[concern]?.lastOrNull;

  /// Put [surface] on top of [concern]: where it mounts, or each time it is
  /// built where the last one built is the one on screen.
  void claim(ShellConcern concern, ShellSurface surface) {
    final stack = _stacks[concern] ??= [];
    if (stack.lastOrNull == surface) return;
    stack
      ..remove(surface)
      ..add(surface);
  }

  /// Take [surface] off [concern]. Answers whether it was on top, and so has
  /// what the shell draws for it to take back.
  bool leave(ShellConcern concern, ShellSurface surface) {
    final stack = _stacks[concern];
    if (stack == null) return false;
    final wasTop = stack.lastOrNull == surface;
    stack.remove(surface);
    return wasTop;
  }
}

final shellSlotsProvider = Provider<ShellSlots>((ref) => ShellSlots());
