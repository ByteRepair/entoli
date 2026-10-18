import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/peers.dart" show PeerState, PeerStatus;
import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry, RemoteProject;
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show ProjectRef;
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/ui/chat/widgets/view_only_bar.dart" show MirrorStrip;
import "package:agent_chat/ui/memory/memory_page.dart" show MemoryTile;
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

/// A project on a paired device: its settings page reads what that device
/// answered, and only what is about the project rather than this disk.
void main() {
  const ProjectRef work = (device: "device-1", project: "work");

  TestApp appWith({required bool online, bool answered = true}) => TestApp.create(
        remotes: [
          RemoteChatEntry(
            chatId: "remote-1",
            deviceId: "device-1",
            deviceName: "Desktop",
            state: ChatState(
              id: "remote-1",
              title: "On the desktop",
              project: "work",
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 2),
            ),
            online: online,
          ),
        ],
        remoteProjects: {
          if (answered)
            work: RemoteProject(
                ProjectSettings(description: "Asked on the desktop", omada: true),
                AppSettings(),
                PromptLibrary([
                  PromptDocument(
                      kind: CompletionKind.skill,
                      name: "deploy",
                      frontmatter: const {},
                      body: ""),
                ])),
        },
      );

  late TestApp app;
  tearDown(() => app.dispose());

  testWidgets("it waits for the device to answer", (tester) async {
    app = appWith(online: true, answered: false);
    await app.pump(tester, const ProjectSettingsPage(project: "work", device: "device-1"),
        settle: false);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text("Project name"), findsNothing);
  });

  testWidgets("it reads the device's settings, less what is on its disk",
      (tester) async {
    app = appWith(online: true);
    await app.pump(tester, const ProjectSettingsPage(project: "work", device: "device-1"));
    await settleIo(tester);

    expect(find.text("Asked on the desktop"), findsOneWidget);
    expect(find.text("Chats"), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(MemoryTile), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text("Round order"), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text("Round order"), findsOneWidget);
    for (final local in ["Path", "Project workspace", "Instructions"]) {
      expect(find.text(local), findsNothing, reason: local);
    }
    expect(find.byType(MirrorStrip), findsNothing);
  });

  // Its library is the device's: listed, and nothing here to open or export.
  testWidgets("its skills are the device's, shown and not changed",
      (tester) async {
    app = appWith(online: true);
    await app.pump(tester, const ProjectSettingsPage(project: "work", device: "device-1"));
    await settleIo(tester);

    await tester.tap(find.text("Skills"));
    await settleIo(tester);
    expect(find.widgetWithText(ListTile, "deploy"), findsOneWidget);
    expect(find.byTooltip("Export deploy"), findsNothing);
    expect(find.text("Import skill"), findsNothing);
  });

  testWidgets("with the device away it is read, not written", (tester) async {
    app = appWith(online: false);
    await app.pump(tester, const ProjectSettingsPage(project: "work", device: "device-1"));
    await settleIo(tester);

    expect(find.byType(MirrorStrip), findsOneWidget);
    expect(find.text("Asked on the desktop"), findsOneWidget);
    expect(
        tester
            .widgetList<AbsorbPointer>(find.byType(AbsorbPointer))
            .any((pointer) => pointer.absorbing),
        isTrue);
  });

  testWidgets("the sidebar opens it from that device's project", (tester) async {
    app = appWith(online: true);
    app.container.read(selectedProjectProvider.notifier).select(work);
    await app.pump(tester, const Sidebar());
    await settleIo(tester);

    await tester.tap(find.byTooltip("Project settings"));
    await settleIo(tester);
    expect(find.byType(ProjectSettingsPage), findsOneWidget);
    expect(find.text("Asked on the desktop"), findsOneWidget);
  });

  test("every project a device names is listed, mirrored or not", () {
    final entries = remoteEntries(const [], {
      "device-1": ["work"],
    }, {
      "device-1": PeerState(
          deviceId: "device-1", name: "Desktop", status: PeerStatus.online),
    });
    final labels = [for (final e in entries) e.label];

    expect(labels, containsAll(["Desktop", "Desktop · work"]));
    expect(entries.firstWhere((e) => e.label == "Desktop · work").scope, work);
  });
}
