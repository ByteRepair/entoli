import "../../domain/app_icon.dart";
import "../../domain/llm_provider.dart";
import "../../domain/models.dart" show ModelChoice;
import "../model_role.dart";
import "scope.dart";
import "spec.dart";

/// What a setting's controller is built from.
class SettingContext {
  SettingContext(this.ref, this.scope, this.spec);

  /// Whatever else the controller reads, watched, so it is rebuilt when that
  /// changes.
  final SettingReader ref;

  final SettingsScope scope;
  final SettingSpec spec;
}

/// One setting, as data: what it is called and says, where it is filed and
/// in what order, how it would like to be drawn, and how its controller is
/// built at a level.
class SettingSpec {
  const SettingSpec({
    required this.id,
    required this.path,
    required this.weight,
    required this.title,
    required this.hint,
    required this.build,
    this.description,
    this.glyph,
  });

  final String id;
  final SettingPath path;

  /// Where it sits in its section: lower first.
  final int weight;

  final String title;
  final String? description;
  final UiHint hint;
  final SettingGlyph? glyph;
  final SettingController Function(SettingContext context) build;
}

/// What a change has to say back, for the frontend to show: a restart a
/// switch needs, what an export wrote.
class SettingNotice {
  const SettingNotice(this.message, {this.title});

  final String? title;
  final String message;
}

/// What an action asks before it runs. With no [confirmLabel] there is
/// nothing to confirm, only something to say, and the action does not run.
class SettingConfirm {
  const SettingConfirm({
    required this.title,
    required this.message,
    this.confirmLabel,
    this.destructive = false,
  });

  final String title;
  final String message;
  final String? confirmLabel;
  final bool destructive;
}

/// What an option looks like where it is more than its label: the colours of
/// a swatch, the radius of a corner, the picture of an icon.
sealed class OptionLook {
  const OptionLook();
}

/// [argb], split diagonally with [second] where there is one.
final class SwatchLook extends OptionLook {
  const SwatchLook(this.argb, [this.second]);

  final int argb;
  final int? second;
}

final class CornerLook extends OptionLook {
  const CornerLook(this.radius);

  final double radius;
}

final class AppIconLook extends OptionLook {
  const AppIconLook(this.icon);

  final AppIcon icon;
}

class SettingOption<T> {
  const SettingOption(
    this.value,
    this.label, {
    this.detail,
    this.enabled = true,
    this.look,
  });

  final T value;
  final String label;

  /// More than the label says: a tooltip, or the line under the field.
  final String? detail;
  final bool enabled;
  final OptionLook? look;
}

/// A titled run of options, as the bold and the pastel colours are.
class OptionGroup<T> {
  const OptionGroup(this.label, this.options);

  final String label;
  final List<SettingOption<T>> options;
}

/// One setting bound to one level: its state, and what may be done to it.
/// Every frontend draws one of these and nothing else, so the rules —
/// which options are on offer, what unset means here, what a change sets
/// off — are said once. Each kind is a kind of behaviour, not a setting:
/// a one-off quirk is a parameter of a kind.
sealed class SettingController {
  SettingController(
    this.spec, {
    String? title,
    String? description,
    this.footnote,
    this.enabled = true,
    this.visible = true,
  }) : title = title ?? spec.title,
       description = description ?? spec.description;

  final SettingSpec spec;

  String get id => spec.id;

  UiHint get hint => spec.hint;

  SettingGlyph? get glyph => spec.glyph;

  final String title;

  /// The line that goes with the field: a switch's subtitle, a dropdown's
  /// helper.
  final String? description;

  /// A paragraph under the field, apart from it.
  final String? footnote;

  final bool enabled;

  /// Whether this platform, or the state of the settings around it, has
  /// anything for this to set. One that is not visible is not drawn.
  final bool visible;
}

/// On or off, or unset where [unsettable].
final class ToggleController extends SettingController {
  ToggleController(
    super.spec, {
    required this.value,
    required this.effective,
    required Future<SettingNotice?> Function(bool? value) onSet,
    this.unsettable = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  /// What is set here, null where nothing is.
  final bool? value;

  /// What is in effect: [value], or what is inherited.
  final bool effective;

  final bool unsettable;
  final Future<SettingNotice?> Function(bool?) _write;

  Future<SettingNotice?> set(bool? value) => _write(value);
}

/// One of [options], or unset where [unsettable]: [inheritedLabel] then
/// names what unset stands for.
final class ChoiceController<T> extends SettingController {
  ChoiceController(
    super.spec, {
    required this.options,
    required this.value,
    required Future<SettingNotice?> Function(T? value) onSet,
    this.unsettable = false,
    this.inheritedLabel,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final List<SettingOption<T>> options;

  /// What is picked, null where nothing is.
  final T? value;

  final bool unsettable;

  /// The label of what unset stands for — the "Relay" of "Default (Relay)" —
  /// where it stands for an option.
  final String? inheritedLabel;

  final Future<SettingNotice?> Function(T?) _write;

  SettingOption<T>? get picked =>
      options.where((o) => o.value == value).firstOrNull;

  Future<SettingNotice?> set(T? value) => _write(value);

  /// [build] called with this controller's own option type, which a switch
  /// over the kinds loses: a frontend's widgets are typed by it.
  R typed<R>(R Function<V>(ChoiceController<V> c) build) => build<T>(this);
}

/// Several values picked from one set of options, a slot at a time: the
/// primary and secondary colours.
final class SlotsController<T> extends SettingController {
  SlotsController(
    super.spec, {
    required this.slots,
    required this.groups,
    required Future<void> Function(int slot, T value) onSet,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final List<SettingOption<T>> slots;
  final List<OptionGroup<T>> groups;
  final Future<void> Function(int, T) _write;

  Future<void> set(int slot, T value) => _write(slot, value);

  /// [build] called with this controller's own option type.
  R typed<R>(R Function<V>(SlotsController<V> c) build) => build<T>(this);
}

/// A whole number, on [stops] where there are some, between [min] and [max]
/// otherwise; unset where [unsettable], which means [inherited].
final class RangeController extends SettingController {
  RangeController(
    super.spec, {
    required this.value,
    required this.inherited,
    required Future<SettingNotice?> Function(int? value) onSet,
    this.stops,
    this.min,
    this.max,
    this.unsettable = true,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final int? value;
  final int inherited;
  final List<int>? stops;
  final int? min;
  final int? max;
  final bool unsettable;
  final Future<SettingNotice?> Function(int?) _write;

  int get effective => value ?? inherited;

  Future<SettingNotice?> set(int? value) => _write(value);
}

/// Names and their values, edited one pair at a time and saved whole.
final class KeyValuesController extends SettingController {
  KeyValuesController(
    super.spec, {
    required this.entries,
    required Future<void> Function(Map<String, String> entries) onSet,
    this.masked = true,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final Map<String, String> entries;

  /// Whether a value is shown as dots: they are mostly keys.
  final bool masked;

  final Future<void> Function(Map<String, String>) _write;

  /// Saves [entries] as the whole of it.
  Future<void> save(Map<String, String> entries) => _write(entries);

  Future<void> put(String name, String value, {String? replacing}) => _write(
    {...entries}
      ..remove(replacing)
      ..[name] = value,
  );

  Future<void> remove(String name) => _write({...entries}..remove(name));
}

/// Something done rather than set, asked first where [confirm] has a
/// question.
final class ActionController extends SettingController {
  ActionController(
    super.spec, {
    required this.label,
    required Future<SettingNotice?> Function() run,
    Future<SettingConfirm?> Function()? confirm,
    this.destructive = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _action = run,
       _ask = confirm;

  final String label;
  final bool destructive;
  final Future<SettingNotice?> Function() _action;
  final Future<SettingConfirm?> Function()? _ask;

  /// What to ask before [run], or null to run it straight away.
  Future<SettingConfirm?> confirm() async => _ask?.call();

  Future<SettingNotice?> run() => _action();
}

/// Settings that are one subject under one label: a switch and the count it
/// turns on, and a line saying what the two of them do together.
final class GroupController extends SettingController {
  GroupController(
    super.spec, {
    required this.children,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  });

  /// Drawn in order; one that is not visible is left out.
  final List<SettingController> children;
}

/// A whole number typed rather than slid to — a value set occasionally —
/// held to [min] and [max], with a reset to [fallback].
final class NumberController extends SettingController {
  NumberController(
    super.spec, {
    required this.value,
    required this.fallback,
    required this.min,
    required this.max,
    required Future<void> Function(int value) onSet,
    this.unit,
    this.prompt,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final int value;
  final int fallback;
  final int min;
  final int max;

  /// What the number counts — "tokens" — said after it.
  final String? unit;

  /// What the field asking for a new one says under it.
  final String? prompt;

  final Future<void> Function(int) _write;

  /// Sets [value] held to the bounds.
  Future<void> set(int value) => _write(value.clamp(min, max));
}

/// One model out of every configured provider, or the entry above them that
/// stores none: what answers new chats, names them, classifies commands.
final class ModelPickController extends SettingController {
  ModelPickController(
    super.spec, {
    required this.choice,
    required this.nullLabel,
    required Future<void> Function(ModelChoice choice) onSet,
    this.defaultOf = LlmProviderConfig.chatDefaultOf,
    this.inherited,
    this.role = ModelRole.agent,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final ModelChoice choice;

  /// What the entry storing nothing is called: "None", "Off", "Default".
  final String nullLabel;

  /// Which of a provider's models its Default entry resolves to.
  final String? Function(LlmProviderConfig) defaultOf;

  /// What the null entry resolves to at the level above.
  final ModelChoice? inherited;

  final ModelRole role;

  final Future<void> Function(ModelChoice) _write;

  Future<void> set(ModelChoice choice) => _write(choice);
}

/// Text, typed in place or in a dialog the row opens; cleared back to empty
/// where it has a [clearLabel].
final class TextController extends SettingController {
  TextController(
    super.spec, {
    required this.value,
    required Future<SettingNotice?> Function(String value) onSet,
    this.emptyLabel,
    this.prompt,
    this.lines = 1,
    this.clearLabel,
    this.secret = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
  }) : _write = onSet;

  final String value;

  /// What the row says while [value] is empty.
  final String? emptyLabel;

  /// What the field asking for it says under it.
  final String? prompt;

  /// How many lines it is typed over: more than one for a list of patterns.
  final int lines;

  /// What clearing it is called, where it can be.
  final String? clearLabel;

  /// Whether it is typed hidden, as a password is.
  final bool secret;

  final Future<SettingNotice?> Function(String) _write;

  Future<SettingNotice?> set(String value) => _write(value);
}
