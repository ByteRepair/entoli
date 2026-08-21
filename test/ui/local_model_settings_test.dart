import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/local_llm.dart";
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
    expect(find.text("Max LLMs running"), findsNothing);
  });

  testWidgets("where it can run one, the catalog is offered with its size",
      (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm());
    await pumpOnDevice(tester);

    expect(find.text(model.name), findsOneWidget);
    expect(find.textContaining("Q4_0"), findsWidgets);
    expect(find.byTooltip("Download"), findsWidgets);
    expect(find.byTooltip("Delete"), findsNothing);
    // Nothing on disk means nothing to configure: the settings above the
    // catalog are all about models, and there are none.
    expect(find.text("Nothing downloaded yet"), findsOneWidget);
    expect(find.text("Max LLMs running"), findsNothing);
  });

  testWidgets("there is no model picker — every downloaded one is offered "
      "wherever a model is chosen", (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id]),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    // The pick used to live here, and having moved it there must be nothing
    // left that looks like one: two places to say which model answers is one
    // that can disagree with the other.
    expect(find.text("Model"), findsNothing);
    expect(find.text("Max LLMs running"), findsOneWidget);
    // Downloaded is not loaded. A gigabyte of memory is spent when a chat asks
    // for the model, not when the file lands.
    expect(app.localLlm.served, isEmpty);
    expect(find.text("Nothing loaded"), findsOneWidget);
  });

  testWidgets("the cap on how many run at once is stored", (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id]),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    await tester.tap(find.text("One at a time"));
    await settleIo(tester);
    await tester.tap(find.textContaining("naming chats beside").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).maxLocalModels, 2);
    // Nothing was started or stopped by the change: the cap is read when a
    // model is next asked for, so a chat mid-reply keeps the model it has.
    expect(app.localLlm.served, isEmpty);
    expect(app.localLlm.stops, 0);
  });

  testWidgets("an accelerator is offered by the name the server gave it",
      (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id], devicesFound: const [
        LocalDevice(
          name: "HTP0",
          description: "Hexagon NPU",
          compute: LocalCompute.npu,
        ),
      ]),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    // "Auto" is the resting label now, not "CPU": null means the best
    // accelerator found, and the CPU is a choice below it.
    await tester.tap(find.text("Auto"));
    await settleIo(tester);
    await tester.tap(find.text("NPU · Hexagon NPU").last);
    await settleIo(tester);

    // The name is passed through untouched: it is what `--device` takes, and a
    // phone can have two of the same kind.
    expect(app.container.read(appSettingsProvider).localModelDevice, "HTP0");
  });

  testWidgets("a phone with no accelerator is told so rather than offered a "
      "dropdown of one", (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id]),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    expect(find.textContaining("no accelerator on this device"), findsOneWidget);
  });

  testWidgets("a loaded model says where it is actually running",
      (tester) async {
    final llm = FakeLocalLlm(installed: [model.id]);
    app = TestApp.create(localLlm: llm, localModels: {model.id});
    await io(tester, () => llm.serve(model.id, device: "Vulkan0"));
    await pumpOnDevice(tester);

    // The resolved device, not the setting: Auto is decided when the model
    // loads, so this row is the only place the answer appears.
    expect(find.textContaining("Answering on the GPU (Vulkan0)"), findsOneWidget);
  });

  testWidgets("a model on the CPU says so rather than naming a device",
      (tester) async {
    final llm = FakeLocalLlm(installed: [model.id]);
    app = TestApp.create(localLlm: llm, localModels: {model.id});
    await io(tester, () => llm.serve(model.id, device: LocalDevice.cpu));
    await pumpOnDevice(tester);

    expect(find.textContaining("Answering on the CPU"), findsOneWidget);
  });

  testWidgets("a model that will not load says why, beside the others",
      (tester) async {
    final llm = FakeLocalLlm(
      installed: [model.id],
      ready: false,
      failure: "not enough memory",
    );
    app = TestApp.create(localLlm: llm, localModels: {model.id});
    // A turn asked for it and it would not come up, which is the only way this
    // row is reached now that the settings page starts nothing. The throw is
    // what a turn would be told, and is not what this test is about.
    await io(tester, () async {
      try {
        await llm.serve(model.id);
      } on LocalLlmFailure {
        // Expected.
      }
    });
    await pumpOnDevice(tester);

    // The server's own last words. For a model too large to fit this is the
    // only place it is said at all.
    expect(find.text("${model.name} would not load"), findsOneWidget);
    expect(find.text("not enough memory"), findsOneWidget);
  });

  testWidgets("unloading everything takes the warm-up with it", (tester) async {
    final llm = FakeLocalLlm(installed: [model.id]);
    app = TestApp.create(localLlm: llm, localModels: {model.id}, prefill: true);
    await io(tester, () => llm.serve(model.id));
    await pumpOnDevice(tester);

    // Held at its serve, which is where a warm-up spends most of its life. From
    // here the page has a spinner on it, so it is pumped rather than settled.
    llm.loading = Completer<void>();
    final warming = app.prefill!.warm(model.id);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining("Prefilling"), findsOneWidget);

    await tester.tap(find.text("Unload all"));
    await tester.pump();
    await tester.pump();

    // Both, and the warm-up first: one left running would go on saying so over
    // a list with nothing in it.
    expect(find.textContaining("Prefilling"), findsNothing);
    expect(app.localLlm.stops, 1);
    expect(app.work.prefills.last, isNull);
    llm.loading!.complete();
    await io(tester, () => warming);
  });

  testWidgets("deleting one that is loaded unloads it first", (tester) async {
    final llm = FakeLocalLlm(installed: [model.id]);
    app = TestApp.create(localLlm: llm, localModels: {model.id});
    await io(tester, () => llm.serve(model.id));
    await pumpOnDevice(tester);

    await tester.tap(find.byTooltip("Delete"));
    await settleIo(tester);
    await tester.tap(find.text("Delete").last);
    await settleIo(tester);

    expect(app.localModels.deleted, [model.id]);
    // The server has the file open, so deleting under it would leave a model
    // answering out of a file that is no longer there.
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

  testWidgets("a model the catalog has dropped is still a row, and deletable",
      (tester) async {
    // Why the store reads the disk rather than the catalog. Swapping a
    // generation of models out is what the catalog is for, and every id it
    // drops is a gigabyte nothing else in the app could reach.
    app = TestApp.create(
        localLlm: FakeLocalLlm(), localModels: {"qwen2.5-coder-3b-q4_0"});
    await pumpOnDevice(tester);

    expect(find.text("qwen2.5-coder-3b-q4_0"), findsOneWidget);
    expect(find.textContaining("not offered any more"), findsOneWidget);

    await tester.tap(find.byTooltip("Delete"));
    await settleIo(tester);
    await tester.tap(find.text("Delete").last);
    await settleIo(tester);

    expect(app.localModels.deleted, ["qwen2.5-coder-3b-q4_0"]);
    expect(app.container.read(installedLocalModelsProvider), isEmpty);
  });

  testWidgets("nothing stale means no such row", (tester) async {
    app = TestApp.create(localLlm: FakeLocalLlm(), localModels: {model.id});
    await pumpOnDevice(tester);

    expect(find.textContaining("not offered any more"), findsNothing);
  });

  testWidgets("turning the KV cache off is stored", (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id]),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    // On by default: the field leads with the ten it resolves to.
    expect(find.text("Default (10)"), findsOneWidget);
    await tester.tap(find.text("Default (10)"));
    await settleIo(tester);
    await tester.tap(find.text("Off").last);
    await settleIo(tester);

    expect(app.container.read(appSettingsProvider).localModelKvCachePrompts, 0);
  });

  testWidgets("the KV cache is counted in prompts, not chats", (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id]),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    // A dump is one request to the model and a turn writes one per step, so
    // every wording here is per prompt — "10 chats" promised conversations kept
    // warm and delivered about two of them.
    expect(find.text("Cached prompts"), findsOneWidget);
    expect(find.textContaining("one for each step"), findsOneWidget);
    expect(find.text("Cached chats"), findsNothing);

    await tester.tap(find.text("Default (10)"));
    await settleIo(tester);
    expect(find.text("30 prompts"), findsOneWidget);
    expect(find.text("30 chats"), findsNothing);
  });

  testWidgets("the cores slider is drawn only where there is more than one core",
      (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id], maxThreads: 8),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    expect(find.text("CPU cores"), findsOneWidget);
    // The default is every core, and that is what the row says until it is moved.
    expect(find.textContaining("All 8 cores"), findsOneWidget);
  });

  testWidgets("a machine that answered with one core has no slider to draw",
      (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id], maxThreads: 1),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    expect(find.text("CPU cores"), findsNothing);
  });

  testWidgets("dragging the slider down stores fewer cores", (tester) async {
    app = TestApp.create(
      localLlm: FakeLocalLlm(installed: [model.id], maxThreads: 8),
      localModels: {model.id},
    );
    await pumpOnDevice(tester);

    await tester.drag(find.byType(Slider), const Offset(-300, 0));
    await settleIo(tester);

    final chosen = app.container.read(appSettingsProvider).localModelThreads;
    expect(chosen, isNotNull);
    expect(chosen, lessThan(8));
  });
}
