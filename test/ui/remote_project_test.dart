import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/peers.dart" show PeerState, PeerStatus;
import "package:agent_chat/data/sync/sync_hub.dart"
    show RemoteChatEntry, RemoteProject;
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show ProjectRef;
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/app/pages/project_settings.dart";
import "package:agent_chat/app/remote_projects.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/selection.dart";

import "../app/pages/page_driver.dart";
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

  test("it waits for the device to answer", () async {
    app = appWith(online: true, answered: false);
    final page = PageDriver(
      app,
      ProjectSettingsAppPage("work", device: "device-1"),
    );
    expect(page.find<NoticeController>("loading"), isNotNull);
    expect(page.find<ActionController>("name"), isNull);
  });

  test(
    "a project the device no longer lists says so rather than wait",
    () async {
      app = appWith(online: true);
      final page = PageDriver(
        app,
        ProjectSettingsAppPage("gone", device: "device-1"),
      );
      await page.until(() => page.find<NoticeController>("gone") != null);
      expect(
        page.at<NoticeController>("gone").lines.single.text,
        "This project is no longer on that device.",
      );
    },
  );

  test("it reads the device's settings, less what is on its disk", () async {
    app = appWith(online: true);
    final page = PageDriver(
      app,
      ProjectSettingsAppPage("work", device: "device-1"),
    );
    await page.until(() => page.find<ActionController>("name") != null);
    expect(
      page.at<TextController>("description").value,
      "Asked on the desktop",
    );
    expect(page.find<InfoController>("chats"), isNotNull);
    expect(page.find<SettingController>("omadaOrdering"), isNotNull);
    expect(page.find<ActionController>("memories"), isNotNull);
    for (final local in ["path", "workspace", "instructions"]) {
      expect(page.find<SettingController>(local), isNull, reason: local);
    }
    expect(
      page.at<NoticeController>("device").lines.single.text,
      "This project lives on Desktop.",
    );
  });

  test("its skills are the device's, shown and not changed", () async {
    app = appWith(online: true);
    final page = PageDriver(
      app,
      ProjectSettingsAppPage("work", device: "device-1"),
    );
    await page.until(() => page.find<ActionController>("skill") != null);
    expect(page.at<ActionController>("skill").label, "1");
  });

  test("with the device away it is read, not written", () async {
    app = appWith(online: false);
    final page = PageDriver(
      app,
      ProjectSettingsAppPage("work", device: "device-1"),
    );
    await page.until(() => page.find<NoticeController>("device") != null);
    expect(page.at<NoticeController>("device").tone, NoticeTone.warning);
    expect(
      page.controllers.whereType<ActionController>().any((a) => a.enabled),
      isFalse,
    );
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
    expect(findPage<ProjectSettingsAppPage>(), findsOneWidget);
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
