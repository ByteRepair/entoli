import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  final model = localModelCatalog.first;

  tearDown(() => app.dispose());

  Future<void> pumpOnDevice(WidgetTester tester) async {
    useWindow(tester, const Size(1200, 1600));
    await pumpSettings(tester, app, SettingsCategory.onDevice);
  }

  testWidgets("a build with no server in it says where the answer is instead, "
      "and offers nothing to download", (tester) async {
    app = TestApp.create();
    await pumpOnDevice(tester);

    expect(find.textContaining("Ollama or LM Studio"), findsOneWidget);
    expect(find.text(model.name), findsNothing);
    expect(find.text("Model"), findsNothing);
  });

  testWidgets("where it can run one, the catalog is offered with its size",
      (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm());
    await pumpOnDevice(tester);

    expect(find.text(model.name), findsOneWidget);
    expect(find.textContaining("Q4_0"), findsWidgets);
    expect(find.byTooltip("Download"), findsWidgets);
    expect(find.byTooltip("Delete"), findsNothing);
    // The picker offers what is on disk, and nothing is — so there is no
    // dropdown to open, only a line saying why.
    expect(find.text("Model"), findsOneWidget);
    expect(find.text("Nothing downloaded yet."), findsOneWidget);
  });

  testWidgets("downloading one adds it to the picker and leaves it unpicked",
      (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm());
    await pumpOnDevice(tester);

    await tester.tap(find.byTooltip("Download").first);
    await settleIo(tester);

    expect(app.container.read(installedLocalModelsProvider), {model.id});
    expect(find.byTooltip("Delete"), findsOneWidget);
    // Downloaded is not the same as loaded: a gigabyte of memory is the user's
    // to spend, and fetching the file is not that.
    expect(app.container.read(appSettingsProvider).localModelId, isNull);
    expect(app.localLlm.started, isEmpty);
  });

  testWidgets("picking one is what starts the server", (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm(), localModels: {model.id});
    await pumpOnDevice(tester);

    await tester.tap(find.byType(DropdownButton<String?>).first);
    await settleIo(tester);
    await tester.tap(find.text(model.name).last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).localModelId, model.id);
    expect(app.localLlm.started.single.modelId, model.id);
    // Nothing named, which is the CPU — the only device every phone has.
    expect(app.localLlm.started.single.device, isNull);
  });

  testWidgets("an accelerator is offered by the name the server gave it",
      (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(devicesFound: const [
        LocalDevice(
          name: "HTP0",
          description: "Hexagon NPU",
          compute: LocalCompute.npu,
        ),
      ]),
      localModels: {model.id},
    );
    await io(tester,
        () => app.container.read(appSettingsProvider.notifier).setLocalModel(model.id));
    await pumpOnDevice(tester);

    await tester.tap(find.text("CPU"));
    await settleIo(tester);
    await tester.tap(find.text("NPU · Hexagon NPU").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).localModelDevice, "HTP0");
    // The name is passed through untouched: it is what `--device` takes, and a
    // phone can have two of the same kind.
    expect(app.localLlm.started.last.device, "HTP0");
  });

  testWidgets("a phone with no accelerator is told so rather than offered a "
      "dropdown of one", (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm(), localModels: {model.id});
    await io(tester,
        () => app.container.read(appSettingsProvider.notifier).setLocalModel(model.id));
    await pumpOnDevice(tester);

    expect(find.textContaining("no accelerator on this device"), findsOneWidget);
  });

  testWidgets("a model that will not load says why, where it was picked",
      (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(ready: false, failure: "not enough memory"),
      localModels: {model.id},
    );
    await io(tester,
        () => app.container.read(appSettingsProvider.notifier).setLocalModel(model.id));
    await pumpOnDevice(tester);

    // The server's own last words. For a model too large to fit this is the
    // only place it is said at all.
    expect(find.text("It would not load"), findsOneWidget);
    expect(find.text("not enough memory"), findsOneWidget);
  });

  testWidgets("deleting the one being served stops it first", (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm(), localModels: {model.id});
    await io(tester,
        () => app.container.read(appSettingsProvider.notifier).setLocalModel(model.id));
    await pumpOnDevice(tester);

    await tester.tap(find.byTooltip("Delete"));
    await settleIo(tester);
    await tester.tap(find.text("Delete").last);
    await settleIo(tester);

    expect(app.localModels.deleted, [model.id]);
    // Unpicked in the same breath: the server has the file open, and a setting
    // naming a deleted model would try to load it again at the next launch.
    expect(app.container.read(appSettingsProvider).localModelId, isNull);
    expect(app.localLlm.stops, greaterThan(0));
  });

  testWidgets("a download in flight shows what it is doing, and can be stopped",
      (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm());
    app.localModels.installing = Completer<void>();
    await pumpOnDevice(tester);

    await tester.tap(find.byTooltip("Download").first);
    await settleIo(tester);

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byTooltip("Cancel"), findsOneWidget);

    await tester.tap(find.byTooltip("Cancel"));
    await settleIo(tester);

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(app.container.read(installedLocalModelsProvider), isEmpty);
  });
}
