import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/background_work.dart";
import "package:agent_chat/domain/rootfs.dart";
import "package:agent_chat/domain/voice_model.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/rootfs_downloads.dart";
import "package:agent_chat/ui/settings/voice_models.dart";

import "../harness.dart";

/// The first entry in each catalog, named once so the assertions below read as
/// being about a download rather than about which model it is.
final tiny = recognitionModels.first;
final aVoice = speechModels.first;

/// What both catalogs get from `Downloads`, asserted through each of them. All
/// a catalog fills in is the wording — `nameOf` and `plural` — and everything
/// else about a download in flight is the shared half. Each page's own tests
/// cover its rows; this covers what a phone is told while it is off screen.
void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  DownloadNotice? lastNotice() => app.work.downloads.last;

  group("the notification", () {
    testWidgets("names the one thing being fetched", (tester) async {
      app = TestApp.create();
      app.voiceModels.installing = Completer<void>();
      await app.pump(tester, const SizedBox());

      app.container.read(voiceModelsProvider.notifier).install(tiny);
      await settleIo(tester);

      expect(lastNotice()?.label, tiny.name);
      expect(lastNotice()?.total, tiny.bytes);
    });

    testWidgets("counts them where there are several, in the catalog's own "
        "words", (tester) async {
      app = TestApp.create();
      app.voiceModels.installing = Completer<void>();
      await app.pump(tester, const SizedBox());

      final downloads = app.container.read(voiceModelsProvider.notifier);
      downloads.install(tiny);
      downloads.install(aVoice);
      await settleIo(tester);

      expect(lastNotice()?.label, "2 voice models");
      expect(lastNotice()?.total, tiny.bytes + aVoice.bytes);
    });

    testWidgets("says systems rather than models for the other catalog",
        (tester) async {
      app = TestApp.create(proot: true);
      app.rootfs.installing = Completer<void>();
      await app.pump(tester, const SizedBox());

      app.container.read(rootfsDownloadsProvider.notifier).install(alpine);
      await settleIo(tester);

      expect(lastNotice()?.label, alpine.name);
    });

    testWidgets("is taken away when the last one finishes", (tester) async {
      app = TestApp.create();
      await app.pump(tester, const SizedBox());

      app.container.read(voiceModelsProvider.notifier).install(tiny);
      await settleIo(tester);

      expect(lastNotice(), isNull);
    });

    testWidgets("and when the notification's own Stop is pressed", (tester) async {
      app = TestApp.create();
      app.voiceModels.installing = Completer<void>();
      await app.pump(tester, const SizedBox());
      app.container.read(voiceModelsProvider.notifier).install(tiny);
      await settleIo(tester);

      // The button asks rather than acts: whoever owns the work stops it, and
      // that is what takes the notification away.
      app.work.stop(BackgroundJob.download);
      await settleIo(tester);

      expect(lastNotice(), isNull);
      expect(app.container.read(voiceModelsProvider).active, isEmpty);
    });
  });

  testWidgets("a run of events that would say the same thing is told to the "
      "platform once", (tester) async {
    app = TestApp.create();
    app.voiceModels
      ..repeats = 40
      ..installing = Completer<void>();
    await app.pump(tester, const SizedBox());

    app.container.read(voiceModelsProvider.notifier).install(tiny);
    await settleIo(tester);

    // Forty events, one notification: a channel call and five binder calls per
    // megabyte is what this rule exists to avoid. The bar still saw all forty.
    expect(app.work.downloads, hasLength(1));
    expect(app.container.read(voiceModelsProvider).active, hasLength(1));
  });

  testWidgets("a download this device has nothing to fetch for starts nothing",
      (tester) async {
    app = TestApp.create(proot: true, abi: "riscv64");
    await app.pump(tester, const SizedBox());

    app.container.read(rootfsDownloadsProvider.notifier).install(alpine);
    await settleIo(tester);

    expect(app.container.read(rootfsDownloadsProvider).active, isEmpty);
    expect(app.container.read(installedRootfsProvider), isEmpty);
    expect(app.work.downloads, isEmpty);
  });

  testWidgets("a failure is remembered against the row, and cleared when it is "
      "tried again", (tester) async {
    app = TestApp.create();
    app.voiceModels.failWith = "the server said no";
    await app.pump(tester, const SizedBox());

    app.container.read(voiceModelsProvider.notifier).install(tiny);
    await settleIo(tester);
    expect(app.container.read(voiceModelsProvider).failures[tiny.id],
        contains("the server said no"));

    app.voiceModels.failWith = null;
    app.container.read(voiceModelsProvider.notifier).install(tiny);
    await settleIo(tester);

    expect(app.container.read(voiceModelsProvider).failures, isEmpty);
    expect(app.container.read(installedVoiceModelsProvider), contains(tiny.id));
  });
}
