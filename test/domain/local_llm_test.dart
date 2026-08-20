import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";

import "../fakes.dart";

/// [applyLocalModel] is the one place that decides what is running, and it is
/// called from two ends — the settings page and startup — so what it does about
/// a server that is *already* running is the whole of it.
void main() {
  final model = localModelCatalog.first;
  final other = localModelCatalog[1];

  AppSettings picking(LocalModel? m, {String? device, int? context}) => AppSettings(
        localModelId: m?.id,
        localModelDevice: device,
        localModelContext: context,
      );

  test("a pick made in a previous run is what starts the server", () async {
    final llm = FakeLocalLlm();

    await applyLocalModel(llm, picking(model, device: "HTP0", context: 8192));

    expect(llm.started.single.modelId, model.id);
    expect(llm.started.single.device, "HTP0");
    expect(llm.started.single.contextLength, 8192);
  });

  test("nothing picked stops whatever was running", () async {
    final llm = FakeLocalLlm();
    await applyLocalModel(llm, picking(model));

    await applyLocalModel(llm, picking(null));

    expect(llm.stops, 1);
  });

  test("the same pick again does nothing", () async {
    // Both callers can arrive at any time — the settings page writes three
    // fields one at a time, and a restore starts a session over a file that has
    // not changed. Reloading a four-gigabyte model for either would be a minute
    // of the phone's time for no change at all.
    final llm = FakeLocalLlm();
    await applyLocalModel(llm, picking(model, device: "HTP0"));

    await applyLocalModel(llm, picking(model, device: "HTP0"));

    expect(llm.started, hasLength(1));
    expect(llm.stops, 0);
  });

  test("a different model, device or context is a reload", () async {
    for (final change in [
      picking(other),
      picking(model, device: "HTP0"),
      picking(model, context: 16384),
    ]) {
      final llm = FakeLocalLlm();
      await applyLocalModel(llm, picking(model));

      await applyLocalModel(llm, change);

      expect(llm.started, hasLength(2));
    }
  });

  test("re-picking the one that failed tries it again", () async {
    // There is nothing else the user could press: the row says why it would not
    // load, and picking it again is how they ask for another go.
    final llm = FakeLocalLlm(ready: false);
    await applyLocalModel(llm, picking(model));

    await applyLocalModel(llm, picking(model));

    expect(llm.started, hasLength(2));
  });

  test("a build with no server in it is left alone", () async {
    final llm = FakeLocalLlm(available: false);

    await applyLocalModel(llm, picking(model));

    expect(llm.started, isEmpty);
    // Not even the stop: there is nothing there to stop, and a settings file
    // carried from a phone names a model this platform has never heard of.
    expect(llm.stops, 0);
  });

  test("a setting naming a model the catalog no longer has stops the server",
      () async {
    final llm = FakeLocalLlm();
    await applyLocalModel(llm, picking(model));

    await applyLocalModel(llm, AppSettings(localModelId: "gone-in-a-later-build"));

    expect(llm.stops, 1);
  });
}
