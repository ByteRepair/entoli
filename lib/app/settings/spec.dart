import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart"
    show ProviderListenable, ProviderOrFamily;

/// How a setting would like to be drawn. A hint, not a kind: a frontend
/// that cannot honour one draws its controller's kind the default way.
enum UiHint {
  /// A switch: the default for a toggle controller.
  toggle,

  /// A dropdown: the default for a choice controller.
  dropdown,

  /// Every option at once, side by side.
  segmented,

  /// The options as their colours.
  swatches,

  /// The options as corners at their own radius.
  corners,

  /// The reasoning effort's slider, its stops named.
  levels,

  /// A slider over stops: the default for a range controller.
  slider,

  /// A list of names and values, each opened to edit: the default for a
  /// key/values controller.
  keyValues,

  /// A button: the default for an action controller.
  button,

  /// A row showing the value, opened to edit it in a dialog: the default for
  /// a text controller.
  row,

  /// A labelled field showing the value, opened to edit it.
  field,

  /// Paragraphs to read: the default for a notice controller.
  notice,

  /// A line with an icon beside it, under what it is about.
  banner,

  /// A line with an icon, set apart on a card of its own.
  card,

  /// A dropdown of what is on this device, saying so where nothing is.
  installed,

  /// One thing to download, kept current with an Update beside Delete.
  single,

  /// Rows to read: the default for an info controller.
  info,

  /// A text field typed into in place.
  input,

  /// A paragraph between fields.
  paragraph,

  /// Devices, each with its state and what can be done to it.
  devices,

  /// Actions side by side in a row.
  buttons,

  /// The service it would be best to start with, while nothing answers.
  recommended,

  /// The endpoints models come from, each with what it has spent.
  providers,

  /// The models loaded now, with what they take up.
  running,

  /// Models to download, each with its facts.
  models,

  /// Tooling to set up: the default for a setup controller.
  setup,

  /// A permission the system holds, and the way to its settings.
  permission,

  /// Triggers, each with what and when, and the switch that arms it.
  triggers,

  /// Agents, each with its face, the whole of its page.
  agents,

  /// Skills, each with what its folder is wrong about, the whole of its page.
  skills,
}

/// The pages settings is filed under, in the order they are offered. A
/// group begins at a page with [groupStart].
enum SettingsPageId {
  general("General"),
  providers("Providers"),
  onDevice("On-device"),
  llms("LLMs"),
  images("Image Generation"),
  memory("Memory", groupStart: true),
  voice("Voice"),
  triggers("Triggers"),
  agents("Agents", groupStart: true),
  skills("Skills"),
  terminal("Terminal", groupStart: true),
  agentBrowser("Agent Browser"),
  byteRepair("Byte Repair"),
  sync("Sync", groupStart: true),
  data("Data"),
  welcome("Welcome", groupStart: true),
  shortcuts("Shortcuts"),
  about("About"),

  // Opened from a row on another page rather than listed.
  syncRelay("Internet relay", listed: false),
  syncTurn("TURN server", listed: false),
  onDeviceLlm("LLM settings", listed: false);

  const SettingsPageId(
    this.title, {
    this.groupStart = false,
    this.listed = true,
  });

  final String title;
  final bool groupStart;

  /// Whether it is offered among the pages, rather than opened from a row.
  final bool listed;
}

/// Where a setting is filed: its page, and the section on it.
typedef SettingPath = ({SettingsPageId page, String section});

/// What a setting reads the rest of the app through: a widget's ref where
/// a frontend builds its controllers in place, a provider's where they are
/// published. [watch] rebuilds the reader's owner on a change.
abstract interface class SettingReader {
  T watch<T>(ProviderListenable<T> provider);

  T read<T>(ProviderListenable<T> provider);

  /// Has [provider] asked again, where what it answered has changed under it.
  /// Nothing where the reader's owner is gone, as it may be by the time an
  /// action's await returns.
  void invalidate(ProviderOrFamily provider);
}

/// A provider's [Ref] as a [SettingReader].
final class RefReader implements SettingReader {
  const RefReader(this.ref);

  final Ref ref;

  @override
  T watch<T>(ProviderListenable<T> provider) => ref.watch(provider);

  @override
  T read<T>(ProviderListenable<T> provider) => ref.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) {
    if (ref.mounted) ref.invalidate(provider);
  }
}

/// A widget's [WidgetRef] as a [SettingReader].
final class WidgetReader implements SettingReader {
  const WidgetReader(this.ref);

  final WidgetRef ref;

  @override
  T watch<T>(ProviderListenable<T> provider) => ref.watch(provider);

  @override
  T read<T>(ProviderListenable<T> provider) => ref.read(provider);

  @override
  void invalidate(ProviderOrFamily provider) {
    if (ref.context.mounted) ref.invalidate(provider);
  }
}

/// A titled part of a page. Its [describe] and [shown] read state, so a
/// section can say something different, or nothing at all, where the
/// platform has nothing for it.
class SectionSpec {
  const SectionSpec({
    required this.page,
    required this.id,
    required this.title,
    required this.weight,
    this.description,
    this.describe,
    this.shown,
    this.keepEmpty = false,
  });

  final SettingsPageId page;
  final String id;
  final String title;

  /// Where it sits on its page: lower first.
  final int weight;

  final String? description;
  final String? Function(SettingReader ref)? describe;
  final bool Function(SettingReader ref)? shown;

  /// Whether its header stands with nothing under it, where what it says is
  /// that there is nothing to set.
  final bool keepEmpty;
}

/// What an icon beside a setting stands for, never how it is drawn: each
/// frontend picks its own picture in an exhaustive switch.
enum SettingGlyph {
  deleteForever,
  play,
  stop,
  warning,
  shield,
  appMark,
  person,
  code,
  privacy,
  licence,
  download,
  upload,
  add,
  notificationsOff,
  alarmOff,
  schedule,
  countdown,
  files,
  online,
  connecting,
  offline,
  failed,
  cloud,
  computer,
  terminal,
  tune,
}
