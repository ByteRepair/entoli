import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/date_words.dart" show describeFire, shortDate;
import "../../../domain/models.dart" show CompletionKind;
import "../../../domain/project.dart";
import "../../../domain/trigger.dart";
import "../../../providers.dart";
import "../controller.dart";
import "../forms/trigger.dart";
import "../spec.dart";

const _page = SettingsPageId.triggers;

/// What the system says of the two permissions a trigger leans on. The rows
/// lead to the system's settings, where the answers can change while the app
/// is behind, so a frontend asks again when it comes back.
final triggerPermissionsProvider =
    FutureProvider<({bool notifications, bool exact})>((ref) async {
      final alarms = ref.watch(reminderAlarmsProvider);
      return (
        notifications: await alarms.notificationsAllowed(),
        exact: await alarms.exactAllowed(),
      );
    });

final triggerSections = [
  SectionSpec(
    page: _page,
    id: "triggers",
    title: "Triggers",
    weight: 0,
    describe: (ref) => ref.watch(reminderAlarmsProvider).schedules
        ? "A trigger sends its prompt to a chat: at a time you pick, "
              "after a countdown, or when a file changes. A schedule "
              "fires even when the app is closed; a countdown or a file "
              "change needs it running."
        : "A trigger sends its prompt to a chat: at a time you pick, "
              "after a countdown, or when a file changes. The app has to "
              "be running for one to fire; one missed while it was closed "
              "is caught up at the next launch.",
  ),
];

final triggerSettings = [
  SettingSpec(
    id: "notificationsOff",
    path: (page: _page, section: "triggers"),
    weight: 0,
    title: "Notifications are off",
    description: "Allow them to see when a trigger finishes.",
    hint: UiHint.permission,
    glyph: SettingGlyph.notificationsOff,
    build: (c) {
      final alarms = c.ref.read(reminderAlarmsProvider);
      return ActionController(
        c.spec,
        label: "Allow",
        visible:
            c.ref.watch(triggerPermissionsProvider).value?.notifications ==
            false,
        run: () async {
          await alarms.requestNotifications();
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "exactOff",
    path: (page: _page, section: "triggers"),
    weight: 10,
    title: "Exact times are not granted",
    description:
        "Without them a schedule may fire minutes late, and its turn can "
        "be cut short while the app is closed.",
    hint: UiHint.permission,
    glyph: SettingGlyph.alarmOff,
    build: (c) {
      final alarms = c.ref.read(reminderAlarmsProvider);
      return ActionController(
        c.spec,
        label: "Allow",
        visible: c.ref.watch(triggerPermissionsProvider).value?.exact == false,
        run: () async {
          await alarms.requestExact();
          return null;
        },
      );
    },
  ),
  // One row per trigger: what and when, with the switch that arms it. Added
  // and edited on the frontend's own editor.
  SettingSpec(
    id: "triggers",
    path: (page: _page, section: "triggers"),
    weight: 20,
    title: "Triggers",
    hint: UiHint.triggers,
    build: (c) {
      final triggers = c.ref.watch(triggersProvider);
      final named = c.ref.watch(projectListProvider).value ?? const <String>[];
      final now = c.ref.watch(clockProvider).now();
      final exact = c.ref.watch(triggerPermissionsProvider).value?.exact;
      final notifier = c.ref.read(triggersProvider.notifier);
      String summary(Trigger trigger) {
        final project = projectOrDefault(trigger.project, named);
        final said = [
          if (trigger.enabled && trigger.nextFireAt != null)
            "${exact != false ? "" : "approx. "}"
                "${describeFire(trigger.nextFireAt!, now)}",
          if (trigger.enabled && trigger.nextFireAt == null)
            if (trigger.source case FileSource(:final paths))
              "File: ${paths.join(", ")}",
          if (trigger.source case ScheduleSource(:final repeat)) repeat.label,
          if (trigger.member != null) "@${trigger.member}",
          if (project != null) projectLabel(project),
          if (trigger.byAgent) "Set by the agent",
        ].join(" · ");
        return said.isNotEmpty
            ? said
            : trigger.lastFiredAt == null
            ? "Never fired"
            : "Last fired ${shortDate(trigger.lastFiredAt!)}";
      }

      TriggerForm form(Trigger? trigger) => TriggerForm(
        trigger,
        now: now,
        projects: [
          for (final project in everyProject(named))
            (project ?? "", projectLabel(project)),
        ],
        members: (project) => c.ref
            .read(promptLibraryProvider(project.isEmpty ? null : project))
            .entries(CompletionKind.agent)
            .map((e) => e.name)
            .toList(),
      );
      return CollectionController<Trigger>(
        c.spec,
        items: triggers,
        addLabel: "Add trigger",
        removable: false,
        describe: (trigger) => CollectionItem(
          trigger.label,
          id: trigger.id,
          subtitle: summary(trigger),
          on: trigger.enabled,
          glyph: switch (trigger.source) {
            ScheduleSource() => SettingGlyph.schedule,
            TimerSource() => SettingGlyph.countdown,
            FileSource() => SettingGlyph.files,
          },
          actions: const [
            ItemAction(
              "delete",
              "Delete",
              destructive: true,
              confirm: SettingConfirm(
                title: "Delete trigger",
                message: "Delete this trigger?",
                confirmLabel: "Delete",
                destructive: true,
              ),
            ),
          ],
        ),
        form: form,
        onSet: (_) async {},
        submit: (answers, index) async {
          final editing = index == null ? null : triggers[index];
          final made = form(editing).build(answers);
          await (editing == null ? notifier.add(made) : notifier.replace(made));
        },
        act: (index, action) async {
          final trigger = triggers[index];
          await switch (action) {
            "toggle" => notifier.setEnabled(trigger.id, !trigger.enabled),
            _ => notifier.remove(trigger.id),
          };
          return null;
        },
      );
    },
  ),
];
