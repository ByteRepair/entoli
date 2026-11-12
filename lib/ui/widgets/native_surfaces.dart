import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/spec.dart" show SettingsPageId;
import "../../domain/agent_browser.dart" show BrowserTab;
import "../../domain/chat_meta.dart";

/// What a frontend that is not Flutter's draws in Flutter's place while it
/// is up: a line said in passing, the dialogs, voice mode, the agent's
/// browser and Settings. The native shell's bridge binds it for the
/// container it runs in; null while Flutter draws everything.
abstract interface class NativeSurfaces {
  void notice(String message);

  NativeDialogs get dialogs;

  void openVoice(String? chatId, ChatMeta? meta);

  void openBrowser(
    BrowserTab tab, {
    required Future<void> Function() onQuit,
    required bool window,
  });

  Future<void> openSettings(SettingsPageId? page);
}

/// A frontend that draws the app's dialogs itself — the native shell's
/// alerts — set by it, so every helper here asks there instead.
abstract interface class NativeDialogs {
  Future<int?> choose(String title, List<String> choices, {int? picked});

  Future<String?> text({
    required String title,
    required String initial,
    required String confirmLabel,
    String? hint,
    String? helper,
    int lines,
    bool allowBlank,
  });

  Future<({String name, String value})?> pair({
    required String title,
    required String nameLabel,
    required String valueLabel,
    String name,
    String value,
  });

  Future<void> tell({required String title, required String message});

  Future<bool> confirm({
    required String title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool destructive,
  });
}

/// Per container, and read when a helper runs rather than watched: nothing
/// draws differently for it, so binding it is no change to tell anyone of.
final nativeSurfacesProvider = Provider<NativeSurfacesBinding>(
  (_) => NativeSurfacesBinding(),
);

class NativeSurfacesBinding {
  NativeSurfaces? _bound;

  NativeSurfaces? get bound => _bound;

  void bind(NativeSurfaces surfaces) => _bound = surfaces;

  /// Only while they are still [surfaces]: a second bridge may have bound its
  /// own since.
  void unbind(NativeSurfaces surfaces) {
    if (identical(_bound, surfaces)) _bound = null;
  }
}

/// The surfaces bound for [context]'s container, null where none are.
NativeSurfaces? nativeSurfacesOf(BuildContext context) =>
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(nativeSurfacesProvider).bound;
