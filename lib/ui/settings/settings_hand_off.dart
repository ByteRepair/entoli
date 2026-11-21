import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/hand_off.dart";
import "../bot_avatar/bot_avatar_editor.dart";
import "../../app/pages/add_local_model.dart";
import "../app_pages.dart";
import "settings_category.dart";
import "paired_device_page.dart";

/// Binds the settings' hand-offs to the app's pages, pushed on [context]'s
/// navigator: what opens for a setting that is more than a setting.
void bindSettingsHandOff(
  SettingsHandOff handOff,
  BuildContext context,
  WidgetRef ref,
) {
  Future<T?> push<T>(Widget page) =>
      Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
  handOff
    ..addModelByLink = (() async =>
        openAppPage(context, AddLocalModelAppPage()))
    ..pairedDevice = ((id) => push<void>(PairedDevicePage(deviceId: id)))
    ..browseBotAvatars = (() => push<void>(const BotAvatarEditorPage.browse()))
    ..openSettings = ((page) => openSettings(
      context,
      category: SettingsCategory.values
          .where((c) => c.page == page)
          .firstOrNull,
      focus: true,
    ));
}

/// [child], with the settings' hand-offs bound for as long as it is up:
/// what the window's root wraps itself in.
class SettingsHandOffs extends ConsumerStatefulWidget {
  const SettingsHandOffs({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SettingsHandOffs> createState() => _SettingsHandOffsState();
}

class _SettingsHandOffsState extends ConsumerState<SettingsHandOffs> {
  late final _handOff = ref.read(settingsHandOffProvider);

  @override
  void initState() {
    super.initState();
    bindSettingsHandOff(_handOff, context, ref);
  }

  @override
  void dispose() {
    _handOff.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
