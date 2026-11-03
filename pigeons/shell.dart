// The native shell's protocol: what the Flutter app tells a client to draw,
// and what the client tells it the user did. Pigeon generates both ends from
// this file — the Dart in `packages/entoli_glass/lib/src/` and the Swift in
// the plugin's `Contract/` — so a field or an intent is said once, and a side
// that disagrees with it does not compile. Run by `tool/prepare.sh`; see
// "Liquid Glass" in `lib/ui/AGENTS.md`.
//
// It is written as a protocol rather than as the bridge's internals: the app
// is the server, holding every rule and every piece of state, and a client
// holds only what the last snapshot of each concern said. Today the one
// client is the SwiftUI shell in this process; nothing here assumes that.
//
// Every class is a value: compared field by field on both sides, so the app
// sends a concern only when it changed.

import "package:pigeon/pigeon.dart";

@ConfigurePigeon(
  PigeonOptions(
    dartPackageName: "entoli_glass",
    dartOut: "packages/entoli_glass/lib/src/shell_contract.g.dart",
    dartTestOut: "test/ui/shell/native_shell.g.dart",
    swiftOut:
        "packages/entoli_glass/darwin/entoli_glass/Sources/entoli_glass/Contract/ShellContract.g.swift",
  ),
)
// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------
/// The appearance the app wears where it is not the system's.
enum Appearance { light, dark }

/// The window around everything: whether a Flutter page covers the
/// conversation — the native chrome steps aside for it — whether the sidebar
/// is shown, and which appearance the app wears, which may not be the
/// system's.
class WindowSnapshot {
  WindowSnapshot({
    required this.covered,
    required this.sidebarShown,
    this.appearance,
  });

  /// A page is pushed over the conversation: Settings, a chat's settings, a
  /// drawer's page. A dialog is not; it draws over the Flutter view alone.
  bool covered;
  bool sidebarShown;

  /// Null for the system's.
  Appearance? appearance;
}

// ---------------------------------------------------------------------------
// The sidebar
// ---------------------------------------------------------------------------

/// A project as the switcher lists it, and as a chat's Move offers it.
/// [device] and [project] are its `ProjectRef`, which an intent hands back.
class ProjectChoice {
  ProjectChoice({
    this.device,
    this.project,
    required this.label,
    required this.symbol,
    this.omada = false,
    this.count = 0,
  });

  String? device;
  String? project;
  String label;

  /// An SF Symbol's name; empty for none.
  String symbol;

  /// Drawn italic, as the Flutter app draws an Omada project's name.
  bool omada;
  int count;
}

/// One chat's row.
class SidebarRow {
  SidebarRow({
    required this.id,
    required this.title,
    this.pinned = false,
    this.busy = false,
    this.temporary = false,
    this.offline = false,
    this.mutable = true,
    this.remote = false,
  });

  String id;
  String title;
  bool pinned;

  /// A turn runs in it, or its browser tab is open.
  bool busy;

  /// It will expire: the hourglass.
  bool temporary;

  /// A mirror whose home device is away.
  bool offline;

  /// Its menu is on offer: false for a mirror whose device is away.
  bool mutable;

  /// A mirror, whose projects are its home device's, so it has no Move.
  bool remote;
}

/// The rows under one heading; a paired device's list is one group with no
/// heading, a mirror answering to no date this sidebar could place it under.
class SidebarGroup {
  SidebarGroup({required this.heading, required this.rows});

  String heading;
  List<SidebarRow> rows;
}

/// A page the app opens over the conversation from the shell's chrome.
enum ShellPage {
  workspace,
  memories,
  projectSettings,
  settings,
  profile,
  marketplace,
}

/// The sidebar: the project being shown and the pages it has beside its
/// chats, its chats under their headings as the search leaves them, and every
/// project for the switcher.
class SidebarSnapshot {
  SidebarSnapshot({
    required this.project,
    this.pages = const [],
    this.groups = const [],
    this.selected,
    this.query = "",
    this.empty,
    this.projects = const [],
    this.devices = const [],
    this.omadaByDefault = false,
  });

  ProjectChoice project;

  /// Of the project's own pages, the ones it has.
  List<ShellPage> pages;
  List<SidebarGroup> groups;
  String? selected;

  /// What the search field holds: the app's, so switching project clears it.
  String query;

  /// What to say where there are no rows, null where there are.
  String? empty;

  /// This device's projects, the default and the built-ins first: the
  /// switcher's, and where a local chat can be moved to.
  List<ProjectChoice> projects;

  /// The paired devices' projects.
  List<ProjectChoice> devices;

  /// What the new-project sheet's Omada switch starts at.
  bool omadaByDefault;
}

// ---------------------------------------------------------------------------
// Title bars: the chat's and a page's
// ---------------------------------------------------------------------------

/// How a [TitleBarItem] is drawn: an icon, a word, a word in the accent's
/// fill, or the page's tick — the system's confirm, where it has one.
enum TitleBarItemStyle { icon, text, prominent, confirm }

/// One choice of a [TitleBarItem] that opens a menu.
class TitleBarMenuItem {
  TitleBarMenuItem({
    required this.id,
    required this.label,
    this.hint,
    this.symbol,
    this.checked = false,
  });

  /// What a pick sends back, as a press's `id`.
  String id;
  String label;

  /// Drawn after the label, quieter: a key or a trigger.
  String? hint;

  /// An SF Symbol's name, drawn before the label.
  String? symbol;

  /// Ticked, as a setting the choice turns on and off.
  bool checked;
}

/// A button of a title bar, or its spinner.
class TitleBarItem {
  TitleBarItem({
    required this.id,
    required this.label,
    this.symbol,
    this.spinner = false,
    this.style = TitleBarItemStyle.icon,
    this.enabled = true,
    this.menu = const [],
  });

  /// What a press sends back, as [TitleBarIntents.press]'s `id`.
  String id;

  /// Its tooltip and accessibility label, and the word a text one shows.
  String label;

  /// An SF Symbol's name; none for the spinner.
  String? symbol;
  bool spinner;
  TitleBarItemStyle style;
  bool enabled;

  /// Its choices, where it opens a menu rather than doing one thing.
  List<TitleBarMenuItem> menu;
}

/// What leads a title bar where something does: a way back, or a close that
/// discards.
enum TitleBarLeading { back, close }

/// A title bar, whichever page it is for: one shape, so one view draws them
/// all. The chat's is [NativeShell.chatBar]; the bar of the Flutter page over
/// the conversation is [NativeShell.pageBar], not [present] where no page has
/// one.
class TitleBarSnapshot {
  TitleBarSnapshot({
    this.present = true,
    required this.title,
    this.subtitle = "",
    this.expiresAt,
    this.leading,
    this.items = const [],
  });

  /// False where there is no bar to draw: the window keeps the chat's title.
  bool present;
  String title;
  String subtitle;

  /// When a temporary chat expires, in milliseconds since the epoch; the
  /// client counts down to it.
  int? expiresAt;
  TitleBarLeading? leading;
  List<TitleBarItem> items;
}

// ---------------------------------------------------------------------------
// The composer
// ---------------------------------------------------------------------------

/// A pending file.
class ComposerAttachment {
  ComposerAttachment({required this.name, required this.image});

  String name;
  bool image;
}

/// One entry of the composer's `/` or `@` menu.
class ComposerMenuItem {
  ComposerMenuItem({required this.label, this.hint, this.detail});

  /// The trigger and the name, as they will be typed.
  String label;
  String? hint;
  String? detail;
}

/// What an embed in the field draws as.
class ComposerCard {
  ComposerCard({this.title, required this.body});

  String? title;
  String body;
}

/// Everything the native composer draws apart from its text, which is
/// [ComposerValueSnapshot]. Not [present] where no page has a composer: a
/// question stands in its place, or the project needs setting up.
class ComposerSnapshot {
  ComposerSnapshot({
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

  bool present;

  /// A `ComposerMode`'s name: `message`, `shell` or `callback`.
  String mode;

  /// What an empty field says.
  String hint;

  /// What Send is called where it is not Stop.
  String sendLabel;
  bool canSend;

  /// What is typed would steer the running turn, so Queue is on offer.
  bool queues;

  /// A turn is running: an empty field's button is Stop.
  bool speaking;

  /// Voice mode can be opened from here.
  bool voice;
  int maxLines;
  List<ComposerAttachment> attachments;

  /// The open completion menu, empty for none.
  List<ComposerMenuItem> menu;

  /// Where a `!` command will run, for shell mode's row.
  String? cwd;

  /// The embeds in the field, by the UTF-16 code unit standing for each.
  Map<int, ComposerCard> cards;

  /// The app's primary colour, as ARGB, which the app's controls wear.
  int accent;

  /// Which appearance the app is drawn in.
  bool dark;
}

/// The composer's text and selection, in UTF-16 code units, sent when the app
/// changed them: a completion taken, a message restored, the field cleared on
/// send. What the user typed is never sent back to them.
class ComposerValueSnapshot {
  ComposerValueSnapshot({
    required this.text,
    required this.start,
    required this.end,
  });

  String text;
  int start;
  int end;
}

// ---------------------------------------------------------------------------
// The turn surface
// ---------------------------------------------------------------------------

/// One thing the chat has running: a pill, standing alone or in its group.
class RunningSnapshot {
  RunningSnapshot({
    required this.id,
    required this.label,
    required this.tooltip,
    this.group,
    this.symbol,
    this.mono = false,
  });

  /// What [TurnIntents.running] names it by.
  int id;
  String label;
  String tooltip;

  /// The kind it is gathered under, as a singular noun; null standing alone.
  String? group;

  /// An SF Symbol in place of the spinner.
  String? symbol;
  bool mono;
}

/// A say the turn has not read yet: its id and its one line.
class SteerSnapshot {
  SteerSnapshot({required this.id, required this.line});

  String id;
  String line;
}

/// A call the turn stopped on, and which answers it offers.
class ApprovalSnapshot {
  ApprovalSnapshot({
    required this.id,
    required this.title,
    required this.symbol,
    required this.tool,
    this.detail,
    this.allow = true,
    this.chat = false,
    this.project = false,
  });

  String id;
  String title;
  String symbol;
  String tool;

  /// The call as the agent worded it, verbatim.
  String? detail;

  /// Allow, Always in chat and Always in project, where each is on offer;
  /// Deny always is.
  bool allow;
  bool chat;
  bool project;
}

/// One option of a question.
class QuestionOption {
  QuestionOption({required this.label, this.detail, required this.answer});

  String label;
  String? detail;

  /// What picking it answers.
  String answer;
}

/// One question the turn asks.
class QuestionSnapshot {
  QuestionSnapshot({
    required this.question,
    this.summary,
    required this.options,
  });

  String question;
  String? summary;
  List<QuestionOption> options;
}

/// What the turn is waiting to be told: the request's id and its questions.
class QuestionRequest {
  QuestionRequest({required this.id, required this.questions});

  String id;
  List<QuestionSnapshot> questions;
}

/// What a running turn puts above the composer: the offer to carry on an
/// interrupted one, what is running, what was said to it unread, and the
/// calls waiting on an answer. Empty where no chat page has one.
class TurnSnapshot {
  TurnSnapshot({
    this.resume,
    this.running = const [],
    this.steers = const [],
    this.withdrawable = false,
    this.approvals = const [],
    this.question,
  });

  /// The resume bar's line, null for none.
  String? resume;
  List<RunningSnapshot> running;
  List<SteerSnapshot> steers;

  /// A say can be taken back into the composer.
  bool withdrawable;
  List<ApprovalSnapshot> approvals;

  /// What the turn is waiting to be told, in the composer's place. The client
  /// holds what is picked until Send, as the Flutter panel does.
  QuestionRequest? question;
}

// ---------------------------------------------------------------------------
// The new-chat screen
// ---------------------------------------------------------------------------

/// A paired device's name, whether it is away, and its projects.
class DeviceSnapshot {
  DeviceSnapshot({
    required this.name,
    required this.offline,
    required this.projects,
  });

  String name;
  bool offline;
  List<ProjectChoice> projects;
}

/// A project picked out, as a [ProjectChoice]'s device and project.
class ProjectPick {
  ProjectPick({this.device, this.project});

  String? device;
  String? project;
}

/// A starter: a `/skill` or `@agent` the library holds.
class StarterSnapshot {
  StarterSnapshot({required this.trigger, required this.name, this.detail});

  /// `/` or `@`.
  String trigger;
  String name;
  String? detail;
}

/// The new-chat screen: the question, the projects as badges — this device's,
/// then each paired device's under its name — with the one the next chat
/// goes to picked out, and a starter per `/skill` and `@agent` the library
/// holds. Not [present] where no page is the new-chat screen.
class NewChatSnapshot {
  NewChatSnapshot({
    required this.present,
    this.question = "",
    this.image,
    this.projects = const [],
    this.devices = const [],
    this.selected,
    this.starters = const [],
    this.starting = false,
  });

  bool present;

  /// What the screen asks; empty asks nothing.
  String question;

  /// The figure over the question, as a Flutter asset key the client finds in
  /// the app's bundle.
  String? image;

  /// This device's projects that have a badge: every one but the default,
  /// which is nothing picked.
  List<ProjectChoice> projects;
  List<DeviceSnapshot> devices;
  ProjectPick? selected;
  List<StarterSnapshot> starters;

  /// A paired device is making the chat: a spinner in the screen's place.
  bool starting;
}

// ---------------------------------------------------------------------------
// Voice mode
// ---------------------------------------------------------------------------

/// One line of the transcript.
class VoiceLineSnapshot {
  VoiceLineSnapshot({required this.kind, required this.text});

  /// `said`, `replied` or `activity`.
  String kind;
  String text;
}

/// Voice mode, drawn over the whole window: the session's status and its
/// word, whether the microphone is shut and what shut means, what went wrong,
/// the chat's title and what has been said. The microphone's level goes on
/// its own, many times a second, as [NativeShell.voiceLevel].
class VoiceSnapshot {
  VoiceSnapshot({
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

  bool present;
  String title;

  /// A `VoiceStatus`'s name.
  String status;

  /// What the screen says this is.
  String word;
  bool paused;

  /// Shut and silent: the one look that is the state's rather than the
  /// status's.
  bool hushed;
  bool pushToTalk;

  /// The session is running: the microphone's button does something.
  bool on;
  String? error;

  /// The transcript's last lines.
  List<VoiceLineSnapshot> lines;

  /// The two voices' colours, as ARGB in this appearance.
  int heard;
  int spoken;
}

// ---------------------------------------------------------------------------
// The palette
// ---------------------------------------------------------------------------

/// One row of the palette: a project to switch to, or a chat to open.
class PaletteItem {
  PaletteItem({
    required this.id,
    required this.label,
    this.chat,
    this.device,
    this.project,
    this.symbol = "",
    this.omada = false,
    this.trailing = "",
    this.busy = false,
    this.current = false,
  });

  /// What it is known by in this snapshot.
  String id;
  String label;

  /// The chat a row opens; null for a project's row.
  String? chat;

  /// A project's `ProjectRef`.
  String? device;
  String? project;
  String symbol;
  bool omada;

  /// A project's chat count, or a chat's project.
  String trailing;

  /// It, or one of its chats, is running.
  bool busy;

  /// The project shown, or the chat open.
  bool current;
}

/// A heading, empty for none, and its rows.
class PaletteSection {
  PaletteSection({required this.heading, required this.items});

  String heading;
  List<PaletteItem> items;
}

/// The project palette, Cmd+K's: whether it is open, what is typed in it, and
/// its rows under their headings as the query leaves them — the app's
/// `ProjectPalette` rules.
class PaletteSnapshot {
  PaletteSnapshot({
    required this.open,
    this.query = "",
    this.sections = const [],
    this.serial = 0,
    this.omadaByDefault = false,
  });

  bool open;
  String query;
  List<PaletteSection> sections;

  /// Which opening this is, so the client starts each one afresh.
  int serial;

  /// What the new-project sheet's Omada switch starts at.
  bool omadaByDefault;
}

// ---------------------------------------------------------------------------
// The reaction strip
// ---------------------------------------------------------------------------

/// One choice of a strip: its glyph, its name, and whether it is picked.
class StripOption {
  StripOption({required this.glyph, required this.name, this.chosen = false});

  String glyph;
  String name;
  bool chosen;
}

/// A strip of choices over the Flutter view, just above the rect of what
/// opened it, in the Flutter view's own coordinates.
class ChoiceStrip {
  ChoiceStrip({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.options,
  });

  double x;
  double y;
  double width;
  double height;
  List<StripOption> options;
}

// ---------------------------------------------------------------------------
// App to client
// ---------------------------------------------------------------------------

/// What the app tells the client. A snapshot is a concern's whole state and
/// replaces what the client held for it; the app sends one only when it
/// changed.
@HostApi(dartHostTestHandler: "TestNativeShell")
abstract class NativeShell {
  /// Take the window. Once per process; a second is answered with nothing to
  /// do.
  void start();

  void window(WindowSnapshot snapshot);
  void sidebar(SidebarSnapshot snapshot);
  void chatBar(TitleBarSnapshot snapshot);
  void pageBar(TitleBarSnapshot snapshot);
  void composer(ComposerSnapshot snapshot);
  void composerValue(ComposerValueSnapshot snapshot);
  void turn(TurnSnapshot snapshot);
  void newChat(NewChatSnapshot snapshot);
  void voice(VoiceSnapshot snapshot);
  void palette(PaletteSnapshot snapshot);

  /// The microphone's level, from 0 to 1: many times a second, with nothing
  /// to compare against.
  void voiceLevel(double level);

  /// Put the caret in the composer's field.
  void focusComposer();

  /// Show [request], answering the one already open as dismissed. Answers the
  /// index picked, or null for a strip dismissed.
  @async
  int? strip(ChoiceStrip request);
}

// ---------------------------------------------------------------------------
// Client to app
// ---------------------------------------------------------------------------

/// The window's own state, which the client reports.
@FlutterApi()
abstract class WindowEvents {
  /// How much of the Flutter view the client's bars cover, which the app
  /// hands the conversation as padding so it scrolls under them.
  @async
  void insets(double left, double top, double right, double bottom);

  /// The sidebar shown or hidden by the client's own control.
  @async
  void sidebarShown(bool shown);
}

/// The sidebar, which is always there.
@FlutterApi()
abstract class SidebarIntents {
  @async
  void search(String query);
  @async
  void openChat(String id);
  @async
  void newChat();
  @async
  void selectProject(String? device, String? project);
  @async
  void pin(String id, bool pinned);
  @async
  void rename(String id, String title);

  /// Into [project] on this device.
  @async
  void move(String id, String? project);
  @async
  void delete(String id);

  /// Answers an error to show, or null once the project is made.
  @async
  String? createProject(String name, String description, bool omada);
  @async
  void openPage(ShellPage page);
}

/// The palette, which is always there.
@FlutterApi()
abstract class PaletteIntents {
  @async
  void search(String query);
  @async
  void close();
  @async
  void pickProject(String? device, String? project);
  @async
  void pickChat(String chat);
}

/// Which files [ComposerIntents.attach] asks for.
enum AttachKind { image, file }

/// Which menu [ComposerIntents.trigger] opens: `/`'s skills or `@`'s agents.
enum ComposerTrigger { skill, agent }

/// The composer on screen.
@FlutterApi()
abstract class ComposerIntents {
  /// The field changed, or its caret moved.
  @async
  void edited(String text, int start, int end);
  @async
  void send();
  @async
  void queue();
  @async
  void stop();
  @async
  void voice();
  @async
  void attach(AttachKind kind);
  @async
  void trigger(ComposerTrigger kind);

  /// A row of the menu as last sent.
  @async
  void pick(int index);
  @async
  void dismiss();
  @async
  void unattach(int index);
  @async
  void unembed(int code);

  /// Take files off the clipboard: answers whether there were any.
  @async
  bool paste();
  @async
  void copyCwd();
}

/// An answer to an approval.
enum ApprovalAnswer { allow, chat, project, deny }

/// The turn surface on screen.
@FlutterApi()
abstract class TurnIntents {
  @async
  void resume();

  /// A [RunningSnapshot] by its id.
  @async
  void running(int id);
  @async
  void queueSteer(String id);
  @async
  void withdraw(String id);
  @async
  void approve(String id, ApprovalAnswer answer);

  /// One answer per question, null for each left unanswered.
  @async
  void answer(String id, List<String?> answers);
}

/// The new-chat screen on screen.
@FlutterApi()
abstract class NewChatIntents {
  @async
  void pick(String? device, String? project);
  @async
  void starter(String trigger, String name);
}

/// Voice mode on screen.
@FlutterApi()
abstract class VoiceIntents {
  @async
  void mute();
  @async
  void talk(bool on);
  @async
  void stop();
  @async
  void done();
}

/// A title bar: the chat's under the channel suffix `chatBar`, a page's under
/// `pageBar`.
@FlutterApi()
abstract class TitleBarIntents {
  @async
  void back();

  /// One of the bar's items, or one of a menu's choices, by its id.
  @async
  void press(String id);
}
