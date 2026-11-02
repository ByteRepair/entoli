import "dart:convert";

import "../../domain/ask.dart" show AskQuestion;

/// What the native shell draws, one concern at a time, and what it sends
/// back. The shell is SwiftUI around the one Flutter view on iOS and macOS
/// with Liquid Glass on; it holds no state of its own past what a snapshot
/// last said, and does nothing but send an [ShellIntent]. Everything here is
/// plain data with a `toMap`, the Swift's `Codable` mirror of it reading the
/// same keys. See "Liquid Glass" in `lib/ui/AGENTS.md`.
///
/// A snapshot is sent only when its map has changed, compared as JSON, since
/// most are rebuilt on every frame a turn streams.
sealed class ShellSnapshot {
  const ShellSnapshot();

  /// Which of the Swift's models it fills, and the key it travels under.
  String get concern;

  Map<String, Object?> toMap();

  String encode() => jsonEncode(toMap());
}

/// The window around everything: whether a Flutter page covers the
/// conversation — the native chrome steps aside for it — whether the sidebar
/// is shown, and which appearance the app wears, which may not be the
/// system's.
class WindowSnapshot extends ShellSnapshot {
  const WindowSnapshot({
    required this.covered,
    required this.sidebarShown,
    required this.appearance,
  });

  /// A page is pushed over the conversation: Settings, a chat's settings, a
  /// drawer's page. A dialog is not; it draws over the Flutter view alone.
  final bool covered;
  final bool sidebarShown;

  /// `light`, `dark`, or null for the system's.
  final String? appearance;

  @override
  String get concern => "window";

  @override
  Map<String, Object?> toMap() => {
    "covered": covered,
    "sidebarShown": sidebarShown,
    "appearance": appearance,
  };
}

/// What the user did in the shell: [name] says what, [args] the rest.
/// Decoded from the map Swift sends; one with a name nothing answers is
/// dropped where it is handled.
class ShellIntent {
  const ShellIntent(this.name, [this.args = const {}]);

  factory ShellIntent.fromMap(Map<Object?, Object?> map) => ShellIntent(
    map["name"]! as String,
    (map["args"] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        const {},
  );

  final String name;
  final Map<String, Object?> args;

  String string(String key) => args[key]! as String;
  String? maybeString(String key) => args[key] as String?;
  bool flag(String key) => args[key] as bool? ?? false;
  int integer(String key) => (args[key]! as num).toInt();
}

/// A project as the switcher lists it, and as a chat's Move offers it.
/// [device] and [project] are its `ProjectRef`, which an intent hands back.
class ProjectChoice {
  const ProjectChoice({
    required this.device,
    required this.project,
    required this.label,
    required this.symbol,
    this.omada = false,
    this.count = 0,
    this.busy = false,
  });

  final String? device;
  final String? project;
  final String label;

  /// An SF Symbol's name.
  final String symbol;

  /// Drawn italic, as the Flutter app draws an Omada project's name.
  final bool omada;
  final int count;

  /// One of its chats is running.
  final bool busy;

  Map<String, Object?> toMap() => {
    "device": device,
    "project": project,
    "label": label,
    "symbol": symbol,
    "omada": omada,
    "count": count,
    "busy": busy,
  };
}

/// One chat's row.
class SidebarRow {
  const SidebarRow({
    required this.id,
    required this.title,
    this.pinned = false,
    this.busy = false,
    this.temporary = false,
    this.offline = false,
    this.mutable = true,
    this.remote = false,
  });

  final String id;
  final String title;
  final bool pinned;

  /// A turn runs in it, or its browser tab is open.
  final bool busy;

  /// It will expire: the hourglass.
  final bool temporary;

  /// A mirror whose home device is away.
  final bool offline;

  /// Its menu is on offer: false for a mirror whose device is away.
  final bool mutable;

  /// A mirror, whose projects are its home device's, so it has no Move.
  final bool remote;

  Map<String, Object?> toMap() => {
    "id": id,
    "title": title,
    "pinned": pinned,
    "busy": busy,
    "temporary": temporary,
    "offline": offline,
    "mutable": mutable,
    "remote": remote,
  };
}

/// The rows under one heading; a paired device's list is one group with no
/// heading, a mirror answering to no date this sidebar could place it under.
class SidebarGroup {
  const SidebarGroup(this.heading, this.rows);

  final String heading;
  final List<SidebarRow> rows;

  Map<String, Object?> toMap() => {
    "heading": heading,
    "rows": [for (final row in rows) row.toMap()],
  };
}

/// The sidebar: the project being shown and the pages it has beside its
/// chats, its chats under their headings as the search leaves them, and every
/// project for the switcher.
class SidebarSnapshot extends ShellSnapshot {
  const SidebarSnapshot({
    required this.project,
    required this.pages,
    required this.groups,
    required this.selected,
    required this.query,
    required this.empty,
    required this.projects,
    required this.devices,
    required this.moveTargets,
    required this.omadaByDefault,
  });

  final ProjectChoice project;

  /// Of `workspace`, `memories` and `projectSettings`, the ones it has.
  final List<String> pages;
  final List<SidebarGroup> groups;
  final String? selected;

  /// What the search field holds: Dart's, so switching project clears it.
  final String query;

  /// What to say where there are no rows, null where there are.
  final String? empty;

  /// This device's projects, the default and the built-ins first.
  final List<ProjectChoice> projects;

  /// The paired devices' projects.
  final List<ProjectChoice> devices;

  /// Where a local chat can be moved to.
  final List<ProjectChoice> moveTargets;

  /// What the new-project sheet's Omada switch starts at.
  final bool omadaByDefault;

  @override
  String get concern => "sidebar";

  @override
  Map<String, Object?> toMap() => {
    "project": project.toMap(),
    "pages": pages,
    "groups": [for (final group in groups) group.toMap()],
    "selected": selected,
    "query": query,
    "empty": empty,
    "projects": [for (final p in projects) p.toMap()],
    "devices": [for (final p in devices) p.toMap()],
    "moveTargets": [for (final p in moveTargets) p.toMap()],
    "omadaByDefault": omadaByDefault,
  };
}

/// One button of the chat's toolbar, or its spinner.
class ToolbarItem {
  const ToolbarItem({
    required this.id,
    required this.label,
    this.symbol,
    this.spinner = false,
  });

  /// What a press sends back, as a `toolbar` intent's `id`.
  final String id;

  /// Its tooltip and accessibility label.
  final String label;

  /// An SF Symbol's name; none for the spinner.
  final String? symbol;
  final bool spinner;

  Map<String, Object?> toMap() => {
    "id": id,
    "label": label,
    "symbol": symbol,
    "spinner": spinner,
  };
}

/// The window's title and toolbar while the conversation is in front: the
/// chat's title, what the Flutter bar said under it, and its buttons.
class ChatBarSnapshot extends ShellSnapshot {
  const ChatBarSnapshot({
    required this.title,
    this.subtitle = "",
    this.expiresAt,
    this.items = const [],
  });

  final String title;
  final String subtitle;

  /// When a temporary chat expires, in milliseconds since the epoch; the
  /// Swift counts down to it.
  final int? expiresAt;
  final List<ToolbarItem> items;

  @override
  String get concern => "chatBar";

  @override
  Map<String, Object?> toMap() => {
    "title": title,
    "subtitle": subtitle,
    "expiresAt": expiresAt,
    "items": [for (final item in items) item.toMap()],
  };
}

/// One entry of the composer's `/` or `@` menu.
class ComposerOptionSnapshot {
  const ComposerOptionSnapshot({
    required this.label,
    this.hint,
    this.description,
  });

  /// The trigger and the name, as they will be typed.
  final String label;
  final String? hint;
  final String? description;

  Map<String, Object?> toMap() => {
    "label": label,
    "hint": hint,
    "description": description,
  };
}

/// Everything the native composer draws apart from its text, which is
/// [ComposerValueSnapshot]. Not [present] where no page has a composer: a
/// question stands in its place, or the project needs setting up.
class ComposerSnapshot extends ShellSnapshot {
  const ComposerSnapshot({
    required this.present,
    this.mode = "message",
    this.hint = "",
    this.sendLabel = "Send",
    this.canSend = false,
    this.queues = false,
    this.speaking = false,
    this.voice = false,
    this.maxLines = 6,
    this.attachments = const [],
    this.menu = const [],
    this.cwd,
    this.cards = const {},
    this.accent = 0xFF007AFF,
    this.dark = false,
  });

  static const absent = ComposerSnapshot(present: false);

  final bool present;

  /// A `ComposerMode`'s name.
  final String mode;

  /// What an empty field says.
  final String hint;

  /// What Send is called where it is not Stop.
  final String sendLabel;
  final bool canSend;

  /// What is typed would steer the running turn, so Queue is on offer.
  final bool queues;

  /// A turn is running: an empty field's button is Stop.
  final bool speaking;

  /// Voice mode can be opened from here.
  final bool voice;
  final int maxLines;

  /// The pending files: each one's name, and whether it is an image.
  final List<({String name, bool image})> attachments;

  /// The open completion menu, empty for none.
  final List<ComposerOptionSnapshot> menu;

  /// Where a `!` command will run, for shell mode's row.
  final String? cwd;

  /// The embeds in the field, by the code unit standing for each.
  final Map<int, ({String? title, String body})> cards;

  /// The app's primary colour, as ARGB, which the app's controls wear.
  final int accent;

  /// Which appearance the app is drawn in.
  final bool dark;

  @override
  String get concern => "composer";

  @override
  Map<String, Object?> toMap() => {
    "present": present,
    "mode": mode,
    "hint": hint,
    "sendLabel": sendLabel,
    "canSend": canSend,
    "queues": queues,
    "speaking": speaking,
    "voice": voice,
    "maxLines": maxLines,
    "attachments": [
      for (final a in attachments) {"name": a.name, "image": a.image},
    ],
    "menu": [for (final option in menu) option.toMap()],
    "cwd": cwd,
    "cards": [
      for (final MapEntry(:key, :value) in cards.entries)
        {"code": key, "title": value.title, "body": value.body},
    ],
    "accent": accent,
    "dark": dark,
  };
}

/// The composer's text and selection, in UTF-16 code units, sent when Dart
/// changed them: a completion taken, a message restored, the field cleared on
/// send. What the user typed is never sent back to them.
class ComposerValueSnapshot extends ShellSnapshot {
  const ComposerValueSnapshot({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final int start;
  final int end;

  @override
  String get concern => "composerValue";

  @override
  Map<String, Object?> toMap() => {"text": text, "start": start, "end": end};
}

/// One thing the chat has running: a pill, standing alone or in its group.
class RunningSnapshot {
  const RunningSnapshot({
    required this.id,
    required this.label,
    required this.tooltip,
    this.group,
    this.symbol,
    this.mono = false,
  });

  /// What a `running` intent names it by.
  final int id;
  final String label;
  final String tooltip;

  /// The kind it is gathered under, as a singular noun; null standing alone.
  final String? group;

  /// An SF Symbol in place of the spinner.
  final String? symbol;
  final bool mono;

  Map<String, Object?> toMap() => {
    "id": id,
    "label": label,
    "tooltip": tooltip,
    "group": group,
    "symbol": symbol,
    "mono": mono,
  };
}

/// A call the turn stopped on, and which answers it offers.
class ApprovalSnapshot {
  const ApprovalSnapshot({
    required this.id,
    required this.title,
    required this.symbol,
    required this.tool,
    this.detail,
    this.allow = true,
    this.chat = false,
    this.project = false,
  });

  final String id;
  final String title;
  final String symbol;
  final String tool;

  /// The call as the agent worded it, verbatim.
  final String? detail;

  /// Allow, Always in chat and Always in project, where each is on offer;
  /// Deny always is.
  final bool allow;
  final bool chat;
  final bool project;

  Map<String, Object?> toMap() => {
    "id": id,
    "title": title,
    "symbol": symbol,
    "tool": tool,
    "detail": detail,
    "allow": allow,
    "chat": chat,
    "project": project,
  };
}

/// What a running turn puts above the composer: the offer to carry on an
/// interrupted one, what is running, what was said to it unread, and the
/// calls waiting on an answer. Empty where no chat page has one.
class TurnSnapshot extends ShellSnapshot {
  const TurnSnapshot({
    this.resume,
    this.running = const [],
    this.steers = const [],
    this.withdrawable = false,
    this.approvals = const [],
    this.question,
  });

  /// What the turn is waiting to be told, in the composer's place: the
  /// request's id and its questions, each with its options. The shell holds
  /// what is picked until Send, as the Flutter panel does.
  final ({String id, List<AskQuestion> questions})? question;

  static const none = TurnSnapshot();

  /// The resume bar's line, null for none.
  final String? resume;
  final List<RunningSnapshot> running;

  /// Each say's id and its one line.
  final List<({String id, String line})> steers;

  /// A say can be taken back into the composer.
  final bool withdrawable;
  final List<ApprovalSnapshot> approvals;

  @override
  String get concern => "turn";

  @override
  Map<String, Object?> toMap() => {
    "resume": resume,
    "running": [for (final r in running) r.toMap()],
    "steers": [
      for (final s in steers) {"id": s.id, "line": s.line},
    ],
    "withdrawable": withdrawable,
    "approvals": [for (final a in approvals) a.toMap()],
    "question": switch (question) {
      null => null,
      (:final id, :final questions) => {
        "id": id,
        "questions": [
          for (final q in questions)
            {
              "question": q.question,
              "summary": q.summary,
              "options": [
                for (final o in q.options)
                  {"label": o.label, "detail": o.detail, "answer": o.answer},
              ],
            },
        ],
      },
    },
  };
}

/// The new-chat screen: the question, the projects as badges — this
/// device's, then each paired device's under its name — with the one the
/// next chat goes to picked out, and a starter per `/skill` and `@agent` the
/// library holds. Not [present] where no page is the new-chat screen.
class NewChatSnapshot extends ShellSnapshot {
  const NewChatSnapshot({
    required this.present,
    this.question = "",
    this.image,
    this.projects = const [],
    this.devices = const [],
    this.selected,
    this.starters = const [],
    this.starting = false,
  });

  static const absent = NewChatSnapshot(present: false);

  final bool present;

  /// What the screen asks; empty asks nothing.
  final String question;

  /// The figure over the question, as a Flutter asset key the Swift finds in
  /// the app's bundle.
  final String? image;

  /// This device's projects that have a badge: every one but the default,
  /// which is nothing picked.
  final List<ProjectChoice> projects;

  /// Each paired device's name, whether it is away, and its projects.
  final List<({String name, bool offline, List<ProjectChoice> projects})>
  devices;

  /// The project picked out, as a `ProjectChoice`'s device and project.
  final ({String? device, String? project})? selected;

  /// Each starter's trigger, name and description.
  final List<({String trigger, String name, String? description})> starters;

  /// A paired device is making the chat: a spinner in the screen's place.
  final bool starting;

  @override
  String get concern => "newChat";

  @override
  Map<String, Object?> toMap() => {
    "present": present,
    "question": question,
    "image": image,
    "projects": [for (final p in projects) p.toMap()],
    "devices": [
      for (final d in devices)
        {
          "name": d.name,
          "offline": d.offline,
          "projects": [for (final p in d.projects) p.toMap()],
        },
    ],
    "selected": switch (selected) {
      null => null,
      (:final device, :final project) => {"device": device, "project": project},
    },
    "starters": [
      for (final s in starters)
        {"trigger": s.trigger, "name": s.name, "description": s.description},
    ],
    "starting": starting,
  };
}

/// Voice mode, drawn by the shell over the whole window: the session's status
/// and its word, whether the microphone is shut and what shut means, what
/// went wrong, the chat's title and what has been said. The microphone's
/// level goes on its own, many times a second, as `voiceLevel`.
class VoiceSnapshot extends ShellSnapshot {
  const VoiceSnapshot({
    required this.present,
    this.title = "Voice",
    this.status = "off",
    this.word = "",
    this.paused = false,
    this.hushed = false,
    this.pushToTalk = false,
    this.on = false,
    this.error,
    this.lines = const [],
    this.heard = 0xFF6C63FF,
    this.spoken = 0xFF2DD4BF,
  });

  static const absent = VoiceSnapshot(present: false);

  final bool present;
  final String title;

  /// A `VoiceStatus`'s name.
  final String status;

  /// What the screen says this is.
  final String word;
  final bool paused;

  /// Shut and silent: the one look that is the state's rather than the
  /// status's.
  final bool hushed;
  final bool pushToTalk;

  /// The session is running: the microphone's button does something.
  final bool on;
  final String? error;

  /// The transcript's last lines: each one's kind (`said`, `replied`,
  /// `activity`) and its text.
  final List<({String kind, String text})> lines;

  /// The two voices' colours, as ARGB in this appearance.
  final int heard;
  final int spoken;

  @override
  String get concern => "voice";

  @override
  Map<String, Object?> toMap() => {
    "present": present,
    "title": title,
    "status": status,
    "word": word,
    "paused": paused,
    "hushed": hushed,
    "pushToTalk": pushToTalk,
    "on": on,
    "error": error,
    "lines": [
      for (final line in lines) {"kind": line.kind, "text": line.text},
    ],
    "heard": heard,
    "spoken": spoken,
  };
}
