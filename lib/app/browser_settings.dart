import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/agent_browser.dart";
import "package:entoli_core/model/settings/keys.dart";

import "../providers.dart";

/// The browsers this machine has, asked once while settings shows them.
final foundBrowsersProvider = FutureProvider.autoDispose<List<FoundBrowser>>(
  (ref) => ref.watch(agentBrowserProvider).detect(),
);

/// Whether the agent's browser is running now.
final browserRunningProvider = NotifierProvider<BrowserRunning, bool>(
  BrowserRunning.new,
);

class BrowserRunning extends Notifier<bool> with ListenableValue<bool> {
  @override
  bool build() => bridge(ref.watch(agentBrowserProvider).running);
}

/// A browser being picked from the disk: started first, to check it can be
/// driven, and why it could not where it could not.
typedef BrowserPick = ({bool verifying, String? problem});

final browserPickProvider = NotifierProvider<BrowserPicker, BrowserPick>(
  BrowserPicker.new,
);

class BrowserPicker extends Notifier<BrowserPick> {
  @override
  BrowserPick build() => (verifying: false, problem: null);

  /// [browser], one detected or the embedded one, or null for none.
  Future<void> pick(String? browser) {
    state = (verifying: false, problem: null);
    return ref.read(appSettingsProvider.notifier).setAgentBrowser(browser);
  }

  /// The executable at [path], picked from the disk, once it has been started
  /// and driven; why not, in [BrowserPick.problem], where it could not be.
  Future<void> pickFile(String path) async {
    state = (verifying: true, problem: null);
    try {
      final exe = await ref.read(agentBrowserProvider).verify(path);
      await ref.read(appSettingsProvider.notifier).setAgentBrowser(exe);
      state = (verifying: false, problem: null);
    } catch (e) {
      state = (verifying: false, problem: "$e");
    }
  }

  /// Whether the browser shows a window. The running one is in the other
  /// mode, so it is closed; the next call starts one in this.
  Future<void> setVisible(bool visible) async {
    await ref.read(appSettingsProvider.notifier).putAll({
      SettingKeys.agentBrowserVisible: visible,
    });
    await ref
        .read(agentBrowserProvider)
        .close(
          why:
              "The browser restarted because the user changed "
              "whether it shows a window.",
        );
  }
}
