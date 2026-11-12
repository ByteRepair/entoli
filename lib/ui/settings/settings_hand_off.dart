import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/hand_off.dart";
import "../../core/log.dart";
import "../bot_avatar/bot_avatar_editor.dart";
import "cli_sign_in_dialog.dart";
import "../../app/pages/add_local_model.dart";
import "../../app/pages/cli_sign_in.dart";
import "../app_pages.dart";
import "paired_device_page.dart";
import "sync_pairing.dart" show ScanQrPage;

/// Binds the settings' hand-offs to the Flutter app's own pages, pushed on
/// [context]'s navigator: what either frontend opens for a setting that is
/// more than a setting. The frontend at the window's root binds them, so
/// both draw the same actions, and clears them when it goes.
void bindSettingsHandOff(
  SettingsHandOff handOff,
  BuildContext context,
  WidgetRef ref,
) {
  Future<T?> push<T>(Widget page) =>
      Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
  handOff
    ..signIn = (config, {again = false}) async {
      final cli = programFor(ref, config);
      if (again) {
        try {
          await cli.signOut();
        } catch (e) {
          logFailure("cli", "signing ${cli.config.displayName} out", e);
        }
      }
      if (!context.mounted) return;
      final page = CliSignInAppPage(cli);
      openAppPage(context, page);
      await page.done;
    }
    ..addModelByLink = (() async =>
        openAppPage(context, AddLocalModelAppPage()))
    ..pairedDevice = ((id) => push<void>(PairedDevicePage(deviceId: id)))
    ..scanCode = (() => push<String>(const ScanQrPage()))
    ..browseBotAvatars = (() => push<void>(const BotAvatarEditorPage.browse()));
}

/// [child], with the settings' hand-offs bound to this frontend's pages for
/// as long as it is up: what the frontend at the window's root wraps itself
/// in.
class SettingsHandOffs extends ConsumerStatefulWidget {
  const SettingsHandOffs({super.key, this.own, required this.child});

  /// The hand-offs a frontend draws itself, bound over the Flutter pages.
  final void Function(SettingsHandOff)? own;

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
    widget.own?.call(_handOff);
  }

  @override
  void dispose() {
    _handOff.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
