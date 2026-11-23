import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/data/sync/peers.dart" show PeerState, PeerStatus;
import "package:agent_chat/data/sync/sync_hub.dart"
    show RemoteChatEntry, RemoteProject;
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/project.dart" show ProjectRef;
import "package:entoli_core/model/project_settings.dart";
import "package:entoli_core/model/prompt_library.dart";
import "package:agent_chat/app/remote_projects.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/selection.dart";

import "../harness.dart";

/// A project on a paired device: its settings page reads what that device
/// answered, and only what is about the project rather than this disk.
void main() {
  const ProjectRef work = (device: "device-1", project: "work");

  TestApp appWith({required bool online, bool answered = true}) =>
      TestApp.create(
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
                  body: "",
                ),
              ]),
            ),
        },
      );

  late TestApp app;
  tearDown(() => app.dispose());

  /// A page still waiting draws a spinner, which never settles.
  Future<void> open(
    WidgetTester tester,
    String project, {
    bool settle = true,
  }) async {
    useWindow(tester, const Size(1000, 4000));
    await app.pump(
      tester,
      ProjectSettingsPage(project: project, device: "device-1"),
      settle: settle,
    );
  }

  testWidgets("it waits for the device to answer", (tester) async {
    app = appWith(online: true, answered: false);
    await open(tester, "work", settle: false);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text("Project name"), findsNothing);
  });

  testWidgets("a project the device no longer lists says so rather than "
      "wait", (tester) async {
    app = appWith(online: true);
    await open(tester, "gone");
    expect(
      find.text("This project is no longer on that device."),
      findsOneWidget,
    );
  });

  testWidgets("it reads the device's settings, less what is on its disk", (
    tester,
  ) async {
    app = appWith(online: true);
    await open(tester, "work");
    expect(find.text("Asked on the desktop"), findsOneWidget);
    expect(find.text("Chats"), findsOneWidget);
    expect(find.text("Default round order"), findsOneWidget);
    expect(find.text("Memories"), findsOneWidget);
    for (final local in ["Path", "Workspace", "Instructions"]) {
      expect(find.text(local), findsNothing, reason: local);
    }
    expect(find.text("This project lives on Desktop."), findsOneWidget);
  });

  testWidgets("its skills are the device's, shown and not changed", (
    tester,
  ) async {
    app = appWith(online: true);
    await open(tester, "work");
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, "Skills"),
        matching: find.text("1"),
      ),
      findsOneWidget,
    );
  });

  testWidgets("with the device away it is read, not written", (tester) async {
    app = appWith(online: false);
    await open(tester, "work");
    expect(
      find.text(
        "Desktop is offline. These settings can be changed once it is back.",
      ),
      findsOneWidget,
    );
    // What it last said is still shown, with nothing to change it.
    expect(find.text("Asked on the desktop"), findsOneWidget);
    for (final row in ["Omada", "Project name", "Delete Project"]) {
      expect(
        tester
            .widgetList<AbsorbPointer>(
              find.ancestor(
                of: find.text(row),
                matching: find.byType(AbsorbPointer),
              ),
            )
            .any((a) => a.absorbing),
        isTrue,
        reason: row,
      );
    }
  });

  testWidgets("the sidebar opens it from that device's project", (
    tester,
  ) async {
    app = appWith(online: true);
    app.container.read(selectedProjectProvider.notifier).select(work);
    await app.pump(tester, const Sidebar());
    await settleIo(tester);

    await tester.tap(find.byTooltip("Project settings"));
    await settleIo(tester);
    expect(find.byType(ProjectSettingsPage), findsOneWidget);
  });

  test("every project a device names is listed, mirrored or not", () {
    final entries = remoteEntries(
      const [],
      {
        "device-1": ["work"],
      },
      {
        "device-1": PeerState(
          deviceId: "device-1",
          name: "Desktop",
          status: PeerStatus.online,
        ),
      },
    );
    final labels = [for (final e in entries) e.label];

    expect(labels, containsAll(["Desktop", "Desktop · work"]));
    expect(entries.firstWhere((e) => e.label == "Desktop · work").scope, work);
  });
}
