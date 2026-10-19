import "dart:io";

import "package:flutter/foundation.dart" show debugDefaultTargetPlatformOverride, TargetPlatform;
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/code_block.dart" show CodeBlock;
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  // Providers are listed alphabetically, so "anthropic" is the one preselected
  // when nothing is persisted.
  const firstProvider = "anthropic";
  const otherProvider = "ollama-cloud";

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  void seedSettings(String providerId, String modelId) =>
      app.seedGlobalDefault(providerId: providerId, modelId: modelId);

  group("the categories", () {
    testWidgets("sit beside the page where there is room for them", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(tester, const SettingsPage());

      expect(find.byIcon(Icons.menu), findsNothing);
      expect(tile("Providers"), findsOneWidget);
      // Beside the list, so the page opens on a category as well as on them.
      expect(find.text("Appearance"), findsOneWidget);
    });

    testWidgets("and are the page itself where there is not", (tester) async {
      await app.pump(tester, const SettingsPage());

      // The list is what settings opens on, and there is no hamburger because
      // there is no drawer to open. Data is near the bottom, below the fold of
      // a test window — proof the list scrolls as well as shows.
      await scrollTo(tester, tile("Data"));
      expect(tile("Data"), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byType(Drawer), findsNothing);
      expect(find.text("Appearance"), findsNothing);
    });

    // Opened for a category, narrow as well as wide: the category is the page
    // itself, nothing behind it, so back leaves settings rather than a list
    // the link skipped.
    testWidgets("initialCategory opens the category directly on a narrow window",
        (tester) async {
      await app.pump(
          tester, const SettingsPage(initialCategory: SettingsCategory.providers));
      await settleIo(tester);

      expect(find.text("Add provider"), findsOneWidget);
      expect(find.widgetWithText(AppBar, "Settings"), findsNothing);
    });

    // The same focus mode on a wide window: the tour's rows and the Byte
    // Repair bar push settings for one category, and the panel has nothing to
    // do with how they got there.
    testWidgets("focus opens the category alone on a wide window", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(
          tester,
          const SettingsPage(
              initialCategory: SettingsCategory.providers, focus: true));
      await settleIo(tester);

      expect(find.text("Add provider"), findsOneWidget);
      expect(find.widgetWithText(AppBar, "Settings"), findsNothing);
      // The panel is not beside what it was not used to pick.
      expect(find.text("Appearance"), findsNothing);
    });

    // A deep-link in without focus is a selection, not a replacement: the
    // panel stays, and the named category is what is showing beside it.
    testWidgets("initialCategory without focus keeps the panel on a wide window",
        (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(
          tester, const SettingsPage(initialCategory: SettingsCategory.providers));
      await settleIo(tester);

      expect(find.text("Add provider"), findsOneWidget);
      expect(find.widgetWithText(AppBar, "Settings"), findsOneWidget);
      expect(tile("General"), findsOneWidget);
      expect(tile("Providers"), findsOneWidget);
    });

    testWidgets("a category is then a page over it, left by the back key", (tester) async {
      final handlesBack = frameworkHandlesBack(tester);
      await app.pump(tester, const SettingsPage());

      await scrollTo(tester, tile("Providers"));
      await tester.tap(tile("Providers"));
      await settleIo(tester);
      expect(find.text("Add provider"), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);

      // Pushing claims the key from Android, which is what makes the press
      // below one a device would actually deliver.
      expect(handlesBack.last, isTrue);
      expect(await pressBack(tester), isTrue);

      expect(find.text("Add provider"), findsNothing);
      await scrollTo(tester, tile("Providers"));
      expect(tile("Providers"), findsOneWidget);
    });

    testWidgets("widening puts the open category beside the list", (tester) async {
      useWindow(tester, const Size(800, 600));
      await app.pump(tester, const SettingsPage());

      await scrollTo(tester, tile("LLMs"));
      await tester.tap(tile("LLMs"));
      await settleIo(tester);
      expect(tile("LLMs"), findsNothing);

      tester.view.physicalSize = const Size(1200, 800);
      await settleIo(tester);

      expect(tile("LLMs"), findsOneWidget);
      expect(find.text("New chats"), findsOneWidget);
    });

    testWidgets("a divider stands where one group ends and another begins",
        (tester) async {
      useWindow(tester, const Size(1200, 1400));
      await app.pump(tester, const SettingsPage());
      final panel = find.ancestor(of: tile("General"), matching: find.byType(ListView));

      // The whole order, dividers included: the walk of the panel reads it as
      // it is drawn. Scoped to the panel: the settings beside it are dividers
      // of their own. Widened until the whole list fits, since the assertion
      // is all seventeen of the categories.
      expect(
        tester
            .widgetList<Widget>(find.descendant(
                of: panel,
                matching: find.byWidgetPredicate(
                    (w) => w is ListTile || w is Divider)))
            .map((w) => w is ListTile ? (w.title! as Text).data! : "─"),
        [
          "General",
          "Providers",
          "On-device",
          "LLMs",
          "Image Generation",
          "─",
          "Memory",
          "Voice",
          "Triggers",
          "─",
          "Agents",
          "Skills",
          "─",
          "Terminal",
          "Byte Repair",
          "─",
          "Sync",
          "Data",
          "─",
          "Welcome",
          "Shortcuts",
          "About",
        ],
      );
    });
  });

  testWidgets("each category holds the settings filed under it", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.general);

    // scrollTo ends in ensureVisible, which throws unless the finder matches
    // exactly one widget — reaching each section is the assertion.
    await scrollTo(tester, find.text("Appearance"));
    await scrollTo(tester, find.text("Agent"));
    await scrollTo(tester, find.text("Environment"));
    await scrollTo(tester, find.text("Delete all chats"));

    await openCategory(tester, SettingsCategory.llms);
    expect(find.text("New chats"), findsOneWidget);
    expect(find.text("Appearance"), findsNothing);

    await openCategory(tester, SettingsCategory.providers);
    expect(find.text("Add provider"), findsOneWidget);
    expect(find.text("New chats"), findsNothing);
  });

  testWidgets("is one field, with no provider to pick first", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.llms);

    expect(find.text("Provider"), findsNothing);
  });

  group("the recommended provider", () {
    testWidgets("stands on an empty page, with both links working", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);

      expect(
          find.textContaining("We recommend Ollama Cloud"), findsOneWidget);
      await tester.tap(find.text("Sign up"));
      await settleIo(tester);
      expect(
          app.linkOpener.opened,
          contains(Uri.parse("https://signin.ollama.com/sign-up")));

      await tester.tap(find.text("Ollama Cloud privacy policy"));
      await settleIo(tester);
      expect(app.linkOpener.opened,
          contains(Uri.parse("https://ollama.com/privacy")));
    });

    // The key box is the thing that actually configures the app: signing up
    // does not, which is why the two steps sit side by side.
    testWidgets("adds Ollama Cloud from a pasted key", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);

      final add = find.widgetWithText(FilledButton, "Add Ollama Cloud");
      expect(tester.widget<FilledButton>(add).onPressed, isNull);

      await tester.enterText(find.byType(TextField), "ollama-key-123");
      await tester.pump();
      expect(tester.widget<FilledButton>(add).onPressed, isNotNull);

      await tester.tap(add);
      await settleIo(tester, least: 8);

      final providers = app.container.read(appSettingsProvider).llmProviders;
      expect(providers.map((p) => p.id), contains("ollama-cloud"));
      expect(app.secrets.providerKey("ollama-cloud"), "ollama-key-123");
      expect(find.textContaining("We recommend Ollama Cloud"), findsNothing);

      // The first provider becomes what every role resolves to, until the
      // user picks something themselves. Adding the card unmounts it on the
      // next frame — the adoption has to survive that, or the pickers stay
      // on None/Off.
      final settings = app.container.read(appSettingsProvider);
      expect(settings.defaultProviderId, "ollama-cloud");
      expect(settings.defaultModelId, isNull);
      expect(settings.titleProviderId, "ollama-cloud");
      expect(settings.titleModelId, isNull);
      expect(settings.memoryProviderId, "ollama-cloud");
      expect(settings.classifierProviderId, "ollama-cloud");
    });

    // The recommended provider group drives one dialog flow three times:
    // menu, Anthropic, Save.
    Future<void> addAnthropic(WidgetTester tester) async {
      await tester.tap(find.text("Add provider"));
      await settleIo(tester);
      await tester.tap(find.text("Anthropic"));
      await settleIo(tester);
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 3);
    }

    // A preset added through the dialog keeps the defaults the preset names:
    // the dialog is a form over the endpoint, not a second place to decide
    // them, and losing them left the picker an initialValue nothing renders.
    testWidgets("a preset added through the dialog keeps its defaults", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.providers);
      await addAnthropic(tester);

      final provider = app.container
          .read(appSettingsProvider)
          .llmProviders
          .firstWhere((p) => p.id == "anthropic");
      expect(provider.defaultModelId, "claude-sonnet-5");
      expect(provider.defaultLightModelId, "claude-haiku-4-5");
    });
  });

  testWidgets("selecting a model persists it with its provider", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.llms);

    await openPickerFor(tester);
    await tester.tap(find.text("Claude Sonnet 4").last);
    await settleIo(tester);

    final settings = app.container.read(appSettingsProvider);
    expect(settings.defaultProviderId, firstProvider);
    expect(settings.defaultModelId, "claude-sonnet-4");
    expect(
      File(app.config.settingsFile).readAsStringSync(),
      contains("claude-sonnet-4"),
    );
  });

  testWidgets("a persisted default is preselected", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester, app, SettingsCategory.llms);

    expect(find.text("Qwen 2.5"), findsOneWidget);
  });

  testWidgets("a saved model the backend no longer offers does not break the page", (tester) async {
    seedSettings(otherProvider, "");
    await pumpSettings(tester, app, SettingsCategory.llms);

    expect(tester.takeException(), isNull);
    expect(find.text(noneOptionLabel), findsOneWidget);
  });

  group("the title model", () {
    Future<void> openTitleDropdown(WidgetTester tester) async {
      // Scoped by the label that precedes it: the model picker above it is a
      // picker of the same type.
      await scrollTo(tester, find.text("Title LLM"));
      await openPickerFor(tester, label: "Title LLM");
    }

    testWidgets("is off until one is picked, and every model is offered", (tester) async {
      useWindow(tester, const Size(800, 1400));
      await pumpSettings(tester, app, SettingsCategory.llms);
      await openTitleDropdown(tester);

      // Off, then all four models by name: nothing inherits from this, so
      // there is no provider to narrow the list to.
      const names = {"Off", "Claude Haiku 3", "Claude Sonnet 4", "Llama 3", "Qwen 2.5"};
      expect(catalogLabels(tester).where(names.contains), [
        "Off",
        "Claude Haiku 3",
        "Claude Sonnet 4",
        "Llama 3",
        "Qwen 2.5",
      ]);
    });

    testWidgets("picking one stores the provider with it", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.llms);
      await openTitleDropdown(tester);

      await tester.tap(find.text("Claude Haiku 3").last);
      await settleIo(tester);

      final settings = app.container.read(appSettingsProvider);
      expect(settings.titleProviderId, firstProvider);
      expect(settings.titleModelId, "claude-haiku-3");
      expect(AppSettings.load(app.config).titleModelId, "claude-haiku-3");
    });

    testWidgets("turning it off drops both halves", (tester) async {
      app.seedSettings(
          AppSettings(titleProviderId: otherProvider, titleModelId: "qwen-2.5"));
      await pumpSettings(tester, app, SettingsCategory.llms);
      expect(find.text("Qwen 2.5"), findsOneWidget);

      await openTitleDropdown(tester);
      await tester.tap(find.text("Off").last);
      await settleIo(tester);

      final settings = app.container.read(appSettingsProvider);
      expect(settings.titleProviderId, isNull);
      expect(settings.titleModelId, isNull);
    });

    testWidgets("a model the backend no longer offers reads as off", (tester) async {
      app.seedSettings(AppSettings(titleProviderId: "gone", titleModelId: "vanished"));
      await pumpSettings(tester, app, SettingsCategory.llms);

      expect(tester.takeException(), isNull);
      final titleLabel = find.text("Title LLM");
      final titleField = find.ancestor(
        of: titleLabel,
        matching: find.byType(LabelledField),
      );
      expect(find.descendant(of: titleField, matching: find.text("Off")), findsOneWidget);
    });
  });

  testWidgets("delete all chats asks first and then clears them", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.general);
    final repo = app.repo;
    await io(tester, () => app.seedChat(title: "one"));
    await io(tester, () => app.seedChat(title: "two"));

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);
    expect(find.textContaining("permanently removes 2 chats"), findsOneWidget);

    await tester.tap(find.text("Delete all"));
    await settleIo(tester);

    expect(await io(tester, () => repo.listChats()), isEmpty);
  });

  testWidgets("cancelling the confirmation keeps the chats", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.general);
    final repo = app.repo;
    await io(tester, () => app.seedChat(title: "one"));

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);
    await tester.tap(find.text("Cancel"));
    await settleIo(tester);

    expect(await io(tester, () => repo.listChats()), hasLength(1));
  });

  testWidgets("with no chats there is nothing to confirm", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.general);

    await scrollTo(tester, find.text("Delete all chats"));
    await tester.tap(find.text("Delete all chats"));
    await settleIo(tester);

    expect(find.text("There are no chats to delete."), findsOneWidget);
    expect(find.text("Delete all"), findsNothing);
  });

  testWidgets("the reset button puts a pinned model back on Default", (tester) async {
    seedSettings(otherProvider, "qwen-2.5");
    await pumpSettings(tester, app, SettingsCategory.llms);
    expect(find.text("Qwen 2.5"), findsOneWidget);

    // No provider is configured in this fixture, so no Default entry exists
    // to name and reset lands on None.
    await tester.tap(find.byTooltip("Reset to $noneOptionLabel").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).defaultProviderId, isNull);
    expect(app.container.read(appSettingsProvider).defaultModelId, isNull);
    expect(find.text("Qwen 2.5"), findsNothing);
  });

  group("environment", () {
    Future<void> addVariable(WidgetTester tester, String name, String value) async {
      await scrollTo(tester, find.text("Add variable"));
      await tester.tap(find.text("Add variable"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).first, name);
      await tester.enterText(find.byType(TextField).last, value);
      await tester.tap(find.text("Save"));
      await settleIo(tester);
    }

    testWidgets("a variable added here reaches the next server", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);

      await addVariable(tester, "ANTHROPIC_API_KEY", "sk-test");

      expect(app.container.read(appSettingsProvider).environment, {"ANTHROPIC_API_KEY": "sk-test"});
      expect(AppSettings.load(app.config).environment, {"ANTHROPIC_API_KEY": "sk-test"});
    });

    testWidgets("the value is masked, so settings can be shown to someone", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await addVariable(tester, "OPENAI_API_KEY", "sk-secret");

      expect(find.text("OPENAI_API_KEY"), findsOneWidget);
      expect(find.text("sk-secret"), findsNothing);
    });

    testWidgets("editing a variable's name does not leave the old one behind", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await addVariable(tester, "OLD_NAME", "value");

      await tester.tap(find.text("OLD_NAME"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).first, "NEW_NAME");
      await tester.tap(find.text("Save"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).environment, {"NEW_NAME": "value"});
    });

    testWidgets("removing one leaves the rest", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.general);
      await addVariable(tester, "KEEP", "1");
      await addVariable(tester, "DROP", "2");

      await tester.tap(find.byTooltip("Remove DROP"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).environment, {"KEEP": "1"});
    });

    testWidgets("the model default survives an environment edit", (tester) async {
      seedSettings(otherProvider, "qwen-2.5");
      await pumpSettings(tester, app, SettingsCategory.general);

      await addVariable(tester, "TOKEN", "abc");

      final settings = app.container.read(appSettingsProvider);
      expect(settings.defaultProviderId, otherProvider);
      expect(settings.defaultModelId, "qwen-2.5");
    });
  });

  group("byte repair", () {
    final project = ByteRepairProject().dir;

    /// The confirm dialog's message, which is the whole of what the store's
    /// [ByteRepairStore.deleteConfirmMessage] buys.
    String deleteMessage(WidgetTester tester) =>
        tester.widget<Text>(find.textContaining("This deletes")).data!;

    /// Opens the delete confirm, answers its message, and closes it again —
    /// the run every message assert here is made of.
    Future<String> deleteDialogMessage(WidgetTester tester) async {
      await scrollTo(tester, find.text("Delete Byte Repair Data"));
      await tester.tap(find.text("Delete Byte Repair Data"));
      await settleIo(tester);
      final message = deleteMessage(tester);
      await tester.tap(find.text("Cancel"));
      await settleIo(tester);
      return message;
    }

    /// A target platform named per test, the way `chat_page_test.dart`'s
    /// `androidTest` does: a `testWidgets` body is Android by default, and
    /// this section is built per target platform.
    void targetTest(String description, TargetPlatform platform,
        Future<void> Function(WidgetTester) body) {
      testWidgets(description, (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    // iOS carries the guest-shaped store: the install destination is the
    // guest's own /usr/local/bin and the gate is the rootfs pick, the way
    // Android's is — its "Host" env being no shell at all. With nothing
    // picked the banner asks for the Linux, the buttons are not drawn, and
    // the delete stays behind a message that names only the data.
    targetTest(
        'iOS with the "Host" env drawn the guest gate and keeps the delete',
        TargetPlatform.iOS, (tester) async {
      // The install dir stays the guest const the harness defaults to; the
      // pick is what gates.
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.text("Run Setup"), findsNothing);
      expect(find.text("Import ESBMC"), findsNothing);
      expect(find.textContaining('using the "Host" terminal environment'),
          findsOneWidget);

      expect(
          await deleteDialogMessage(tester),
          "This deletes the Byte Repair workspace (cloned repos, scratch "
          "files) and all chats in the project.");
    });

    // The same platform with the Alpine from the Terminal settings picked:
    // the guest's destination is where the setup installs, so the buttons
    // come back — the pick, not the platform, is the gate. No per-project
    // copy is made on iOS — the iSH shell runs the base Alpine — so the
    // dialog names nothing the setup left on the host's disk.
    targetTest("an installed Alpine puts the buttons back on iOS",
        TargetPlatform.iOS, (tester) async {
      app.dispose();
      app = TestApp.create(linuxes: const {"alpine"});
      await io(tester, () => app.container
          .read(appSettingsProvider.notifier).setRootfs("alpine"));
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.text("Run Setup"), findsOneWidget);
      expect(find.text("Import ESBMC"), findsOneWidget);

      expect(
          await deleteDialogMessage(tester),
          "This deletes the Byte Repair workspace (cloned repos, scratch "
          "files) and all chats in the project. Run Setup to use Byte "
          "Repair again.");
    });

    // A mac's setup installs with Homebrew: the page says so before the
    // button is pressed, and with no Homebrew it is the command to paste,
    // drawn as a reply's code block with its copy button.
    targetTest("a mac says Homebrew installs, and gives its install command "
        "where it is missing", TargetPlatform.macOS, (tester) async {
      app.dispose();
      final bin = p.join(app.config.dataDir, "byte-repair", "bin");
      app = TestApp.create(byteRepairInstallDir: bin);
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.textContaining("Run Setup uses Homebrew"), findsOneWidget);
      expect(find.textContaining("Homebrew is not installed"), findsOneWidget);
      expect(find.byType(CodeBlock), findsOneWidget);
      expect(find.byTooltip("Copy code"), findsOneWidget);
      expect(find.text("Run Setup"), findsOneWidget);
    });

    targetTest("a mac with Homebrew has no command to paste",
        TargetPlatform.macOS, (tester) async {
      app.dispose();
      final bin = p.join(app.config.dataDir, "byte-repair", "bin");
      final brew = p.join(app.config.dataDir, "brew");
      app = TestApp.create(byteRepairInstallDir: bin, byteRepairBrewPaths: [brew]);
      File(brew).writeAsStringSync("");
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.textContaining("Run Setup uses Homebrew"), findsOneWidget);
      expect(find.byType(CodeBlock), findsNothing);
    });

    targetTest("the fetched tools a setup left are named, the rootfs never",
        TargetPlatform.linux, (tester) async {
      app.dispose();
      final bin = p.join(app.config.dataDir, "byte-repair", "bin");
      app = TestApp.create(byteRepairInstallDir: bin);
      Directory(bin).createSync(recursive: true);
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.text("Run Setup"), findsOneWidget);
      expect(find.text("Import ESBMC"), findsOneWidget);

      final message = await deleteDialogMessage(tester);
      expect(message,
          contains("the tools the setup fetched into the app's cache directory"));
      expect(message, contains("Run Setup to use Byte Repair again"));
      expect(message, isNot(contains("rootfs")));
    });

    // The env check passes where a rootfs is picked, so the buttons come
    // back and the message names the copy the setup made.
    targetTest(
        "an Android rootfs env puts the buttons back, with the rootfs named",
        TargetPlatform.android, (tester) async {
      app.dispose();
      app = TestApp.create(proot: true, linuxes: const {"alpine"});
      Directory(p.join(app.config.projectDir(project: project), "rootfs"))
          .createSync(recursive: true);
      await io(tester, () => app.container
          .read(appSettingsProvider.notifier).setRootfs("alpine"));
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.text("Run Setup"), findsOneWidget);

      expect(
          await deleteDialogMessage(tester), contains("the Byte Repair rootfs"));
    });

    // The Host env cannot run a setup, the same banner Android's Host has
    // always drawn — and the delete stays, naming the workspace and the
    // chats alone where the copy is not there. The store is built as the
    // factory builds it on Android — the guest's /usr/local/bin as the
    // install dir — which is exactly why the banner asks about the pick and
    // the dialog names no host tree.
    targetTest("Android's Host env draws the env banner and keeps the delete",
        TargetPlatform.android, (tester) async {
      await pumpSettings(tester, app, SettingsCategory.byteRepair);

      expect(find.text("Run Setup"), findsNothing);
      expect(
          find.textContaining('when using the "Host" terminal environment'),
          findsOneWidget);

      expect(await deleteDialogMessage(tester), isNot(contains("rootfs")));
    });
  });
}