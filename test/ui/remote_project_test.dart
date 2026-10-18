import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/peers.dart" show PeerState, PeerStatus;
import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry, RemoteProject;
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show ProjectRef;
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/ui/chat/widgets/view_only_bar.dart" show MirrorStrip;
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
                AppSettings()),
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
    expect(find.text("Round order"), findsOneWidget);
    expect(find.text("Chats"), findsOneWidget);
    for (final local in ["Path", "Project workspace", "Instructions", "Project memories"]) {
      expect(find.text(local), findsNothing, reason: local);
    }
    expect(find.byType(MirrorStrip), findsNothing);
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
