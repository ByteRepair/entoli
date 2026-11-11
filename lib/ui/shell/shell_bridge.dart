import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app_command.dart";
import "../app_menu.dart";
import "../command_intents.dart";
import "../commands.dart";
import "../chat/chat_page.dart";
import "shell_palette.dart";
import "shell_publisher.dart";
import "../settings/settings_category.dart" show nativeSettingsOpener;
import "../../app/settings/hand_off.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../core/log.dart";
import "../bot_avatar/bot_avatar_editor.dart";
import "../settings/cli_sign_in_dialog.dart";
import "../settings/local_model_settings.dart" show AddLocalModelPage;
import "../settings/paired_device_page.dart";
import "../settings/sync_pairing.dart" show ScanQrPage;
import "shell_settings.dart";
import "shell_sidebar.dart";
import "shell_window.dart";

/// The app under the native shell, in `AppShell`'s place: the Flutter half of
/// a window SwiftUI owns. It asks the Swift to take the window, sends it the
/// snapshots it draws, runs what it sends back, and draws the open
/// conversation, [ChatPage]. The shell's bars reach it, and every page over
/// it, as padding, so it scrolls under them: see [ShellInsets]. The pages it
/// pushes draw over it inside the same view. The commands and their keys
/// attach here as they do to `AppShell`, and the menu bar is the same
/// `AppMenuSync`, going where this frontend goes through [shellNavigate].
class ShellBridge extends ConsumerStatefulWidget {
  const ShellBridge({super.key});

  @override
  ConsumerState<ShellBridge> createState() => _ShellBridgeState();
}

class _ShellBridgeState extends ConsumerState<ShellBridge> {
  late final CommandScope _scope = ref.read(commandScopeProvider);

  /// The window's, the sidebar's and the palette's snapshots, sent as they
  /// change.
  late final ShellPublisher _publisher;

  /// Every settings page, sent to the client's own settings as it changes.
  late final SettingsBridge _settings;

  /// The bridge the shell's events reach, which is the last one mounted. A
  /// restart builds the next session's before it takes this one down, so the
  /// one going unbinds them only while they are still its own.
  static _ShellBridgeState? _listening;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
    _scope.attach(_commands);
    _listening = this;
    _bind(this);
    final container = ProviderScope.containerOf(context, listen: false);
    _publisher = ShellPublisher(container);
    _settings = SettingsBridge(container);
    nativeSettingsOpener = _settings.show;
    // The avatar editor is Flutter's on every frontend: opened over the
    // conversation, the native settings stepping aside for it.
    final handOff = container.read(settingsHandOffProvider);
    handOff.editBotAvatar = (initial) =>
        Navigator.of(context).push<BotAvatarSpec>(
          MaterialPageRoute(
            builder: (_) => BotAvatarEditorPage(initial: initial),
          ),
        );
    handOff.signIn = (config, {again = false}) async {
      final cli = programFor(ref, config);
      if (again) {
        try {
          await cli.signOut();
        } catch (e) {
          logFailure("cli", "signing ${cli.config.displayName} out", e);
        }
      }
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CliSignInDialog(cli: cli),
      );
    };
    handOff.addModelByLink = () => Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const AddLocalModelPage()));
    handOff.pairedDevice = (id) => Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => PairedDevicePage(deviceId: id)),
    );
    handOff.scanCode = () => Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanQrPage()));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _scope.detach(_commands);
    _publisher.close();
    _settings.close();
    if (nativeSettingsOpener == _settings.show) nativeSettingsOpener = null;
    if (identical(_listening, this)) {
      _listening = null;
      _bind(null);
    }
    super.dispose();
  }

  /// What the shell sends under no surface's name — the window's own, the
  /// sidebar's, the palette's — to [bridge], or to nothing. The surfaces'
  /// own go to whichever answers for each, through `ShellAnswers`.
  static void _bind(_ShellBridgeState? bridge) {
    WindowEvents.setUp(bridge == null ? null : WindowRunner(bridge.ref));
    SidebarIntents.setUp(
      bridge == null ? null : SidebarRunner(bridge.context, bridge.ref),
    );
    PaletteIntents.setUp(
      bridge == null ? null : PaletteRunner(bridge.context, bridge.ref),
    );
  }

  Commands _commands() => Commands.read(context, ref, shellNavigate);

  /// The items' keys where no menu bar holds them. See `AppShell`.
  bool _key(KeyEvent event) => runKey(event, ref, _commands);

  @override
  Widget build(BuildContext context) =>
      const AppMenuSync(navigate: shellNavigate, child: ChatPage());
}

/// This frontend's way to every [Destination]: the native palette for a
/// project, and the Flutter pages it draws over the conversation for the
/// rest. Exhaustive, so a new one is decided here as well as in Flutter's.
Future<void> shellNavigate(Commands c, Destination to) async {
  switch (to) {
    case Destination.switchProject:
      c.ref.read(shellPaletteProvider.notifier).open();
    case Destination.about ||
        Destination.settings ||
        Destination.profile ||
        Destination.marketplace ||
        Destination.backUp ||
        Destination.welcome ||
        Destination.keyboardShortcuts ||
        Destination.toggleSidebar ||
        Destination.chatSettings ||
        Destination.showPlan ||
        Destination.voiceMode ||
        Destination.projectWorkspace ||
        Destination.projectMemories ||
        Destination.projectSettings:
      await flutterNavigate(c, to);
  }
}
