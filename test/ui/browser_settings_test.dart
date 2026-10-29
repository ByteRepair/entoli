import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/browser/cdp_browser.dart";
import "package:agent_chat/data/browser/helium.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";

import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  // Android's browser is the app's WebView: a switch, with nothing to pick,
  // no window to show and no Helium to download.
  testWidgets("Android turns the WebView on and off rather than picking a "
      "browser", (tester) async {
    app = TestApp.create(
      browser: (config) => CdpBrowser(
        browserDir: p.join(config.dataDir, "browser"),
        picked: () => AppSettings.load(config).agentBrowser,
        visible: () => AppSettings.load(config).agentBrowserVisible,
        embedded: HeliumDownload(p.join(config.dataDir, "browser")),
        webViews: const MethodChannel("agent_chat/browser"),
      ),
    );
    useWindow(tester, const Size(1200, 1600));
    await pumpSettings(tester, app, SettingsCategory.agentBrowser);

    expect(find.text("Show the browser window"), findsNothing);
    expect(find.text("Embedded browser"), findsNothing);
    final browser = app.container.read(agentBrowserProvider);
    expect(browser.configured, isFalse);

    await tester.tap(find.text("Let the agent use a browser"));
    await tester.pumpAndSettle();
    expect(browser.configured, isTrue);

    await tester.tap(find.text("Let the agent use a browser"));
    await tester.pumpAndSettle();
    expect(browser.configured, isFalse);
  });
}
