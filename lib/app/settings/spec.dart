import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

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

  /// The options as the app's icons.
  icons,

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

  /// A field typed into in place.
  field,
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
  about("About");

  const SettingsPageId(this.title, {this.groupStart = false});

  final String title;
  final bool groupStart;
}

/// Where a setting is filed: its page, and the section on it.
typedef SettingPath = ({SettingsPageId page, String section});

/// What a setting reads the rest of the app through: a widget's ref where
/// a frontend builds its controllers in place, a provider's where they are
/// published. [watch] rebuilds the reader's owner on a change.
abstract interface class SettingReader {
  T watch<T>(ProviderListenable<T> provider);

  T read<T>(ProviderListenable<T> provider);
}

/// A provider's [Ref] as a [SettingReader].
final class RefReader implements SettingReader {
  const RefReader(this.ref);

  final Ref ref;

  @override
  T watch<T>(ProviderListenable<T> provider) => ref.watch(provider);

  @override
  T read<T>(ProviderListenable<T> provider) => ref.read(provider);
}

/// A widget's [WidgetRef] as a [SettingReader].
final class WidgetReader implements SettingReader {
  const WidgetReader(this.ref);

  final WidgetRef ref;

  @override
  T watch<T>(ProviderListenable<T> provider) => ref.watch(provider);

  @override
  T read<T>(ProviderListenable<T> provider) => ref.read(provider);
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
  });

  final SettingsPageId page;
  final String id;
  final String title;

  /// Where it sits on its page: lower first.
  final int weight;

  final String? description;
  final String? Function(SettingReader ref)? describe;
  final bool Function(SettingReader ref)? shown;
}

/// What an icon beside a setting stands for, never how it is drawn: each
/// frontend picks its own picture in an exhaustive switch.
enum SettingGlyph { deleteForever }
