import "dart:typed_data";

import "../../domain/bot_avatar/spec.dart" show BotAvatarSpec;
import "../../domain/download.dart" show DownloadProgress;
import "../../domain/installable.dart" show ModelFacts;
import "../../domain/llm_provider.dart";
import "../../domain/models.dart" show ModelChoice;
import "../app_items.dart" show AppKey;
import "../model_role.dart";
import "pairing.dart";
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

  /// A part of this setting — a group's child, an accessory — under an id of
  /// its own beneath this one's, so a frontend can name it in an intent.
  SettingContext part(
    String id,
    String title, {
    UiHint hint = UiHint.toggle,
    SettingGlyph? glyph,
  }) => SettingContext(
    ref,
    scope,
    SettingSpec(
      id: "${spec.id}.$id",
      path: spec.path,
      weight: 0,
      title: title,
      hint: hint,
      glyph: glyph,
      build: spec.build,
    ),
  );
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
    this.at,
  });

  final String id;
  final SettingPath path;

  /// Where it sits in its section: lower first.
  final int weight;

  final String title;
  final String? description;
  final UiHint hint;
  final SettingGlyph? glyph;

  /// The level it is always set at, whatever level its page is shown for:
  /// the default project's rules on the app's Terminal page.
  final ScopeAddress? at;

  final SettingController Function(SettingContext context) build;
}

/// What a change has to say back, for the frontend to show: a restart a
/// switch needs, what an export wrote.
class SettingNotice {
  const SettingNotice(this.message, {this.title, this.copy});

  final String? title;
  final String message;

  /// Text put on the clipboard as the notice is said: an install link.
  final String? copy;
}

/// What an action asks before it runs. With no [confirmLabel] there is
/// nothing to confirm, only something to say, and the action does not run.
class SettingConfirm {
  const SettingConfirm({
    required this.title,
    required this.message,
    this.confirmLabel,
    this.destructive = false,
  }) : brief = false,
       cancelled = false;

  /// Something to say in passing, and the action does not run.
  const SettingConfirm.note(this.message)
    : title = "",
      confirmLabel = null,
      destructive = false,
      brief = true,
      cancelled = false;

  /// Nothing to say, and the action does not run: the file picker it opened
  /// was dismissed.
  const SettingConfirm.nothing()
    : title = "",
      message = "",
      confirmLabel = null,
      destructive = false,
      brief = false,
      cancelled = true;

  final String title;
  final String message;
  final String? confirmLabel;
  final bool destructive;
  final bool brief;
  final bool cancelled;
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
    this.accessory,
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

  /// Something done beside it, drawn at its end: hearing the voice picked.
  final ActionController? accessory;
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
    super.accessory,
  }) : set = onSet;

  /// What is set here, null where nothing is.
  final bool? value;

  /// What is in effect: [value], or what is inherited.
  final bool effective;

  final bool unsettable;
  final Future<SettingNotice?> Function(bool? value) set;
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
    this.noneLabel,
    this.error,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : set = onSet;

  final List<SettingOption<T>> options;

  /// What is picked, null where nothing is.
  final T? value;

  final bool unsettable;

  /// The label of what unset stands for — the "Relay" of "Default (Relay)" —
  /// where it stands for an option.
  final String? inheritedLabel;

  /// What picking nothing is called where nothing is an answer of its own
  /// rather than an inherited one: "Device language".
  final String? noneLabel;

  /// What went wrong with the last pick, said under the field.
  final String? error;

  final Future<SettingNotice?> Function(T? value) set;

  SettingOption<T>? get picked =>
      options.where((o) => o.value == value).firstOrNull;

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
    super.accessory,
  }) : set = onSet;

  final List<SettingOption<T>> slots;
  final List<OptionGroup<T>> groups;
  final Future<void> Function(int slot, T value) set;

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
    this.commitOnEnd = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : set = onSet;

  /// Whether it is written once a drag ends rather than as it moves: each
  /// write of the cores restarts the server.
  final bool commitOnEnd;

  final int? value;
  final int inherited;
  final List<int>? stops;
  final int? min;
  final int? max;
  final bool unsettable;
  final Future<SettingNotice?> Function(int? value) set;

  int get effective => value ?? inherited;
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
    super.accessory,
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
    this.glyphOverride,
    required Future<SettingNotice?> Function() run,
    Future<SettingConfirm?> Function()? confirm,
    this.destructive = false,
    this.secondary = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : _action = run,
       _ask = confirm;

  final String label;

  /// The picture where it is not the spec's: a play button that is a stop
  /// button while it plays.
  final SettingGlyph? glyphOverride;

  @override
  SettingGlyph? get glyph => glyphOverride ?? super.glyph;

  final bool destructive;

  /// Whether it is the lesser of two side by side: drawn outlined.
  final bool secondary;

  final Future<SettingNotice?> Function() _action;
  final Future<SettingConfirm?> Function()? _ask;

  /// What to ask before [run], or null to run it straight away.
  Future<SettingConfirm?> confirm() async => _ask?.call();

  Future<SettingNotice?> run() => _action();
}

/// Settings that are one subject under one label: a switch and the count it
/// turns on, and a line saying what the two of them do together; or actions
/// side by side, with [busy] while one of them runs.
final class GroupController extends SettingController {
  GroupController(
    super.spec, {
    required this.children,
    this.busy = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  });

  /// Drawn in order; one that is not visible is left out.
  final List<SettingController> children;

  /// Whether one of its actions is running, which holds the others.
  final bool busy;
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
    super.accessory,
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
    super.accessory,
  }) : set = onSet;

  final ModelChoice choice;

  /// What the entry storing nothing is called: "None", "Off", "Default".
  final String nullLabel;

  /// Which of a provider's models its Default entry resolves to.
  final String? Function(LlmProviderConfig) defaultOf;

  /// What the null entry resolves to at the level above.
  final ModelChoice? inherited;

  final ModelRole role;

  final Future<void> Function(ModelChoice choice) set;
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
    this.allowBlank = false,
    this.submitLabel,
    this.clearLabel,
    this.secret = false,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : set = onSet;

  final String value;

  /// What the row says while [value] is empty.
  final String? emptyLabel;

  /// What the field asking for it says under it.
  final String? prompt;

  /// How many lines it is typed over: more than one for a list of patterns.
  final int lines;

  /// What saving it is called where it is a button of its own beside the
  /// field: "Add Ollama Cloud".
  final String? submitLabel;

  /// Whether an empty answer is one: clearing it by typing nothing.
  final bool allowBlank;

  /// What clearing it is called, where it can be.
  final String? clearLabel;

  /// Whether it is typed hidden, as a password is.
  final bool secret;

  final Future<SettingNotice?> Function(String value) set;
}

/// Something to read rather than set: lines of text, and links out.
final class NoticeController extends SettingController {
  NoticeController(
    super.spec, {
    required this.lines,
    this.tone = NoticeTone.plain,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  });

  final List<NoticeLine> lines;

  /// How much it matters: a warning is drawn in the error colour.
  final NoticeTone tone;
}

enum NoticeTone { plain, good, warning }

/// A paragraph, or a link where it has a [url].
class NoticeLine {
  const NoticeLine(this.text, {this.url});

  final String text;
  final Uri? url;
}

/// Items of one kind — permission rules, providers, agents — each opened to
/// edit through a [SettingForm] and removed on its own, and added to at the
/// end of the list.
final class CollectionController<T> extends SettingController {
  CollectionController(
    super.spec, {
    required this.items,
    required this.addLabel,
    Future<void> Function(List<T> items)? onSet,
    required this.describe,
    this.form,
    this.removeLabel = "Remove",
    this.removable = true,
    this.emptyLabel,
    Future<SettingNotice?> Function(int index, String action)? act,
    Future<void> Function(Map<String, String> answers, int? index)? submit,
    Future<void> Function(int index, Uint8List png)? image,
    Future<void> Function(int index, BotAvatarSpec spec)? botAvatar,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : _write = onSet ?? _keep,
       _onAct = act,
       _onSubmit = submit,
       _onImage = image,
       _onBotAvatar = botAvatar;

  final List<T> items;
  final String addLabel;
  final String removeLabel;

  /// Whether an item can be removed from its row.
  final bool removable;

  /// What the list says while it is empty.
  final String? emptyLabel;

  final Future<SettingNotice?> Function(int, String)? _onAct;

  final Future<void> Function(Map<String, String>, int?)? _onSubmit;
  final Future<void> Function(int, Uint8List)? _onImage;
  final Future<void> Function(int, BotAvatarSpec)? _onBotAvatar;

  /// Whether an item can wear a Bot Avatar, which a frontend picks with its
  /// own page of them.
  bool get takesBotAvatars => _onBotAvatar != null;

  /// Sets the item at [index]'s face to [spec].
  Future<void> setBotAvatar(int index, BotAvatarSpec spec) async =>
      _onBotAvatar?.call(index, spec);

  /// Whether an item's picture can be set from a PNG the user picked.
  bool get takesImages => _onImage != null;

  /// Sets the item at [index]'s picture to [png].
  Future<void> setImage(int index, Uint8List png) async =>
      _onImage?.call(index, png);

  /// Saves what a form for the item at [index], or a new one, was answered
  /// with: the item the answers make, unless saving one does more than
  /// keeping it, as a provider's key going to the secret store does.
  Future<void> submit(Map<String, String> answers, {int? index}) {
    if (_onSubmit case final submit?) return submit(answers, index);
    final made = form!(index == null ? null : items[index]).build(answers);
    return put(made, index: index);
  }

  /// Runs the item action [action] on the item at [index].
  Future<SettingNotice?> act(int index, String action) async =>
      _onAct?.call(index, action);

  /// What an item's row says.
  final CollectionItem Function(T item) describe;

  /// The form an item is added or edited through, given the item or null
  /// for a new one; null where items are not edited here.
  final SettingForm<T> Function(T? item)? form;

  /// Whether items are added and edited through [form]: asked of the
  /// controller itself, where its own item type is known.
  bool get editable => form != null;

  final Future<void> Function(List<T>) _write;

  List<CollectionItem> get rows => [for (final item in items) describe(item)];

  /// [item] in place of the one at [index], or added at the end.
  Future<void> put(T item, {int? index}) => _write(
    [...items]
      ..removeAtOrNot(index)
      ..add(item),
  );

  Future<void> remove(int index) => _write([...items]..removeAt(index));

  /// [build] called with this controller's own item type.
  R typed<R>(R Function<V>(CollectionController<V> c) build) => build<T>(this);
}

/// A collection whose items are kept by its [CollectionController.submit]
/// and item actions alone.
Future<void> _keep(List<Object?> _) async {}

extension on List {
  void removeAtOrNot(int? index) {
    if (index != null) removeAt(index);
  }
}

/// An item's row: its name, the line under it, and what can be done to it
/// from the row besides opening and removing it.
class CollectionItem {
  const CollectionItem(
    this.title, {
    this.id,
    this.removeLabel,
    this.subtitle,
    this.error,
    this.glyph,
    this.tone = NoticeTone.plain,
    this.actions = const [],
    this.on,
    this.opens,
    this.tap,
    this.badge,
    this.face,
    this.editable = true,
    this.takesImage = true,
  });

  final String title;

  /// What removing it is called, where the list's own word is not enough.
  final String? removeLabel;

  /// What it is known by, where a frontend opens a page of its own for it.
  final String? id;

  final String? subtitle;

  /// What went wrong with it last, in the error colour.
  final String? error;

  /// Its state at a glance: a device online, connecting, unreachable.
  final SettingGlyph? glyph;
  final NoticeTone tone;

  final List<ItemAction> actions;

  /// Whether it is armed, where its row carries a switch: flipped through the
  /// item action "toggle".
  final bool? on;

  /// A page of the app's that tells more of it.
  final TextPage? opens;

  /// A word set beside it: where an entry not of this level came from,
  /// "Bundled", "Inherited".
  final String? badge;

  /// The agent whose face leads the row.
  final ({String? project, String name})? face;

  /// Whether it is edited through the list's form: an entry of another
  /// level's is shown and not changed.
  final bool editable;

  /// Whether its picture can be set, where the list takes pictures.
  final bool takesImage;

  /// The item action a tap on the row runs, where the row is not edited
  /// through a form: a device's own page.
  final String? tap;
}

/// A page of text the app holds, which a row opens: each frontend draws it
/// from what the app holds.
sealed class TextPage {
  const TextPage();
}

final class PolicyPage extends TextPage {
  const PolicyPage();
}

/// The libraries the app is built on, and their licences.
final class LicencesPage extends TextPage {
  const LicencesPage();
}

/// A skill as its view page tells it: [origin] is where it came from, or
/// "Not loaded".
final class SkillPage extends TextPage {
  const SkillPage(this.name, {required this.origin, this.project});

  final String name;
  final String? project;
  final String origin;
}

/// Something done to one item from its row: connect, disconnect, revoke.
class ItemAction {
  const ItemAction(
    this.id,
    this.label, {
    this.enabled = true,
    this.destructive = false,
    this.confirm,
    this.handsOff = false,
  });

  final String id;
  final String label;
  final bool enabled;
  final bool destructive;

  /// Whether it opens a page of the Flutter app's, which a frontend drawing
  /// the settings itself steps aside for.
  final bool handsOff;

  /// What it asks first; null runs it straight away.
  final SettingConfirm? confirm;
}

/// A form that adds or edits one item: the questions asked given the answers
/// so far, what is wrong with them, and the item they make. Every frontend
/// draws [fields] again after each answer, so a question that depends on
/// another comes and goes with it.
abstract class SettingForm<T> {
  const SettingForm();

  /// "Add rule", "Edit rule".
  String get title;

  /// Whether it is long enough to be a page of its own rather than a
  /// dialog, where a frontend has the difference.
  bool get page => false;

  /// What leaving it with something typed asks, where leaving loses it.
  String? get discard => null;

  /// Told when it is left without saving, for what it made on the way: a
  /// program signed in under a new entry's id.
  Future<void> dismissed(Map<String, String> answers) async {}

  /// The answers it opens with.
  Map<String, String> get initial;

  List<FormFieldSpec> fields(Map<String, String> answers);

  /// Why it cannot be saved, or null where it can. Empty where a field
  /// already says so, or where there is nothing to say yet.
  String? problem(Map<String, String> answers);

  /// The item [answers] make. Called only where [problem] is null.
  T build(Map<String, String> answers);
}

/// One part of a form.
sealed class FormFieldSpec {
  const FormFieldSpec();
}

/// A heading over the fields that answer it.
final class FormQuestion extends FormFieldSpec {
  const FormQuestion(this.text);

  final String text;
}

/// Text typed in.
final class FormText extends FormFieldSpec {
  const FormText(
    this.id,
    this.label, {
    this.hint,
    this.helper,
    this.error,
    this.focused = false,
    this.lines = 1,
    this.enabled = true,
    this.secret = false,
    this.file = false,
  });

  final String id;
  final String label;
  final String? hint;
  final String? helper;
  final String? error;

  /// How many lines it is typed over.
  final int lines;

  final bool enabled;

  /// Whether the caret starts here.
  final bool focused;

  /// Whether it is typed hidden, as a key is.
  final bool secret;

  /// Whether a file picked from the disk can fill it, its path the answer.
  final bool file;
}

/// Prose the model reads — a trigger's prompt, a system prompt — written
/// where `/skills` and `@agents` complete from [project]'s library, and
/// shown the way the chat sets it where a frontend can.
final class FormPrompt extends FormFieldSpec {
  const FormPrompt(
    this.id,
    this.label, {
    this.hint,
    this.project,
    this.enabled = true,
  });

  final String id;
  final String label;
  final String? hint;

  /// Whose library completes it: null is the default project.
  final String? project;
  final bool enabled;
}

/// One of [options], each by its answer; the help of the one picked is said
/// under it. [segmented] asks for every option side by side; [cards] for
/// each as a row of its own with its detail and tags, under its group, the
/// whole of the form while nothing is picked.
final class FormChoice extends FormFieldSpec {
  const FormChoice(
    this.id,
    this.options, {
    this.label,
    this.segmented = false,
    this.cards = false,
    this.enabled = true,
  });

  final String id;
  final String? label;
  final List<FormOption> options;
  final bool segmented;
  final bool cards;
  final bool enabled;
}

/// A link out of the app: where a key is made, a provider's policy.
/// [prominent] is the one thing the form is waiting on the user to do.
final class FormLink extends FormFieldSpec {
  const FormLink(this.label, this.url, {this.prominent = false});

  final String label;
  final Uri url;
  final bool prominent;
}

/// What a part answers once switched on or agreed to: a fold opened, a
/// consent given, a refused save made anyway.
const formYes = "yes";

/// The fields after it folded away until it is opened: answered [formYes], or
/// nothing while shut. Which fields it holds is the form's to say.
final class FormFold extends FormFieldSpec {
  const FormFold(this.id, this.label);

  final String id;
  final String label;

  bool open(Map<String, String> answers) => answers[id] == formYes;
}

/// Something the user has to agree to before the rest is asked: answered
/// [formYes] once they do.
final class FormConsent extends FormFieldSpec {
  const FormConsent(
    this.id, {
    required this.title,
    required this.message,
    required this.accept,
    this.link,
  });

  final String id;
  final String title;
  final String message;

  /// What agreeing is called: "I understand, add it".
  final String accept;

  /// Where the terms behind it are read, and what that is called.
  final (String, Uri)? link;

  bool given(Map<String, String> answers) => answers[id] == formYes;
}

/// Names and their values, one `NAME=value` a line: what a program runs
/// with.
final class FormEntries extends FormFieldSpec {
  const FormEntries(this.id, this.label, {this.helper, this.enabled = true});

  final String id;
  final String label;
  final String? helper;
  final bool enabled;

  /// How the answer is typed, where it is typed as text.
  static const format = "One NAME=value a line.";

  static Map<String, String> decode(String? answer) => {
    for (final line in (answer ?? "").split("\n"))
      if (line.indexOf("=") case final at when at > 0)
        line.substring(0, at).trim(): line.substring(at + 1),
  };

  static String encode(Map<String, String> entries) => [
    for (final MapEntry(:key, :value) in entries.entries) "$key=$value",
  ].join("\n");
}

/// [config]'s program signed in, from inside the form: where its account
/// stands, and Sign in, or Sign in again.
final class FormSignIn extends FormFieldSpec {
  const FormSignIn(this.config);

  final LlmProviderConfig config;
}

/// Why a Save was refused, thrown by a submit: said on [field], with Save
/// turned into [anywayLabel] where saving the same again is allowed — the
/// answer [anyway] then set [formYes], and cleared once [field] changes.
class FormRefusal implements Exception {
  const FormRefusal(this.field, this.message, {this.anyway, this.anywayLabel});

  final String field;
  final String message;
  final String? anyway;
  final String? anywayLabel;

  @override
  String toString() => message;
}

/// A moment, answered as ISO 8601 local time.
final class FormDate extends FormFieldSpec {
  const FormDate(this.id, this.label, {this.enabled = true});

  final String id;
  final String label;
  final bool enabled;
}

/// A length of time, answered in whole minutes.
final class FormDuration extends FormFieldSpec {
  const FormDuration(this.id, this.label, {this.helper, this.enabled = true});

  final String id;
  final String label;
  final String? helper;
  final bool enabled;
}

/// Any of [options], answered as their answers joined by commas. Options of
/// one [FormOption.kind] are one thing worded two ways: picking one unpicks
/// the others. With [all], the label is a switch over the lot: on while each
/// kind has one picked, and switched on, each kind's first.
final class FormMulti extends FormFieldSpec {
  const FormMulti(
    this.id,
    this.label,
    this.options, {
    this.error,
    this.enabled = true,
    this.all = false,
  });

  final String id;
  final String label;
  final List<FormOption> options;
  final String? error;
  final bool enabled;
  final bool all;

  static Set<String> decode(String? answer) => {
    for (final pick in (answer ?? "").split(","))
      if (pick.isNotEmpty) pick,
  };

  static String encode(Iterable<String> picks) => picks.join(",");

  String _kind(FormOption option) => option.kind ?? option.answer;

  /// [picked] with [answer] switched [on].
  Set<String> toggled(Set<String> picked, String answer, bool on) {
    final option = options.firstWhere((o) => o.answer == answer);
    return {
      for (final p in picked)
        if (p != answer &&
            !(on &&
                options.any((o) => o.answer == p && _kind(o) == _kind(option))))
          p,
      if (on) answer,
    };
  }

  /// Whether every kind has one of its options in [picked].
  bool allOn(Set<String> picked) => options.every(
    (o) =>
        options.any((p) => _kind(p) == _kind(o) && picked.contains(p.answer)),
  );

  /// [picked] with every option switched [on] — each kind's first — or off.
  Set<String> withAll(Set<String> picked, bool on) {
    final mine = {for (final o in options) o.answer};
    final kinds = <String>{};
    return {
      for (final p in picked)
        if (!mine.contains(p)) p,
      if (on)
        for (final o in options)
          if (kinds.add(_kind(o))) o.answer,
    };
  }
}

/// Words to read in the form: why a part of it cannot be changed.
final class FormNote extends FormFieldSpec {
  const FormNote(this.text);

  final String text;
}

class FormOption {
  const FormOption(
    this.answer,
    this.label, {
    this.help,
    this.group,
    this.tags = const [],
    this.glyph,
    this.kind,
  });

  final String answer;
  final String label;

  /// What it is beyond its name: said under the picked one, and under each
  /// where they are cards.
  final String? help;

  /// The heading a card sits under.
  final String? group;

  /// What it is at a glance, a card's chips.
  final List<FormTag> tags;
  final SettingGlyph? glyph;

  /// What it is underneath, where two options are one thing worded two
  /// ways: in a [FormMulti], picking one unpicks the other.
  final String? kind;
}

class FormTag {
  const FormTag(this.text, {this.tone = NoticeTone.plain});

  final String text;
  final NoticeTone tone;
}

/// Things this device downloads — a Linux, a model — each with the one
/// thing that can be done to it now: download, cancel, or delete.
final class CatalogController extends SettingController {
  CatalogController(
    super.spec, {
    required this.items,
    required Future<void> Function(String id) download,
    required Future<void> Function(String id) cancel,
    required Future<void> Function(String id) delete,
    this.addLabel,
    Future<void> Function()? add,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : _onDownload = download,
       _onCancel = cancel,
       _onDelete = delete,
       _onAdd = add;

  final List<CatalogItem> items;

  /// Where something not in the catalog can be added by its link.
  final String? addLabel;

  final Future<void> Function(String) _onDownload;
  final Future<void> Function(String) _onCancel;
  final Future<void> Function(String) _onDelete;
  final Future<void> Function()? _onAdd;

  /// Adds one by its link, through the page that asks for it.
  Future<void> add() async => _onAdd?.call();

  Future<void> download(String id) => _onDownload(id);

  Future<void> cancel(String id) => _onCancel(id);

  /// Called only once [CatalogItem.deleteConfirm], where there is one, has
  /// been agreed to.
  Future<void> delete(String id) => _onDelete(id);
}

class CatalogItem {
  const CatalogItem({
    required this.id,
    required this.title,
    this.deleteConfirm,
    this.summary,
    this.note,
    this.badge,
    this.facts,
    this.failure,
    this.progress,
    this.installed = false,
    this.downloadable = true,
    this.updatable = false,
  });

  final String id;
  final String title;
  final String? summary;
  final String? note;

  /// A word set beside its name: "Multilingual".
  final String? badge;

  /// What a model is, each fact a tag of its own.
  final ModelFacts? facts;

  /// Why the last attempt stopped.
  final String? failure;

  /// Where it is being fetched right now.
  final DownloadProgress? progress;

  final bool installed;

  /// Whether this device can fetch it at all: a row that cannot is drawn
  /// dead rather than left out, so the reader can see it exists.
  final bool downloadable;

  /// Whether one already here can be fetched again for a newer one.
  final bool updatable;

  /// What deleting it asks first; null deletes it straight away.
  final SettingConfirm? deleteConfirm;
}

/// Rows to read: what the app is, the keys that do what.
final class InfoController extends SettingController {
  InfoController(
    super.spec, {
    required this.rows,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  });

  final List<InfoRow> rows;
}

class InfoRow {
  const InfoRow(
    this.title, {
    this.subtitle,
    this.glyph,
    this.keys,
    this.link,
    this.opens,
  });

  final String title;
  final String? subtitle;
  final SettingGlyph? glyph;

  /// The chord that does it, drawn as each keyboard prints it.
  final AppKey? keys;

  /// A page out of the app it opens.
  final Uri? link;

  /// A page of the app's own it opens.
  final TextPage? opens;
}

/// Pairing another device, through [flow], which a frontend's own screens
/// drive step by step; [activity] is the pairing in flight as it stood when
/// this was built.
final class PairingController extends SettingController {
  PairingController(
    super.spec, {
    required this.flow,
    required this.activity,
    this.scanner,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  });

  final PairingFlow flow;

  /// The pairing in flight, or null.
  final PairingActivity? activity;

  /// The camera page, answering the code it read: a phone's, the device
  /// pointed at a code.
  final Future<String?> Function()? scanner;

  bool get canScan => scanner != null;

  /// Reads a code another screen shows and pairs with it.
  Future<String?> scan() async {
    final code = await scanner?.call();
    if (code == null || code.isEmpty) return null;
    return flow.join(code);
  }
}

/// Another page of settings, opened from a row on this one.
final class SubpageController extends SettingController {
  SubpageController(
    super.spec, {
    required this.page,
    this.summary,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  });

  final SettingsPageId page;

  /// What the row says the page holds now: the relay's address.
  final String? summary;
}

/// Tooling put in place for a project to work: what stands in its way, the
/// command to run first where one is needed, setting it up and importing a
/// piece of it by hand, what is installed now, and taking it all away.
final class SetupController extends SettingController {
  SetupController(
    super.spec, {
    required this.tools,
    required this.running,
    required Future<void> Function() setUp,
    required Future<void> Function() import,
    required Future<void> Function() delete,
    required this.deleteConfirm,
    required this.setUpLabel,
    required this.importLabel,
    required this.deleteLabel,
    this.blocked,
    this.notice,
    this.prerequisite,
    this.error,
    super.title,
    super.description,
    super.footnote,
    super.enabled,
    super.visible,
    super.accessory,
  }) : _onSetUp = setUp,
       _onImport = import,
       _onDelete = delete;

  /// Why it cannot run here at all, where it cannot: nothing else is offered.
  final String? blocked;

  /// Something to know before running it.
  final String? notice;

  /// A command to run by hand first, and why.
  final ({String why, String command})? prerequisite;

  /// Each tool and the version found, null where it is not installed; null
  /// while they are being asked.
  final Map<String, String?>? tools;

  final bool running;

  /// What went wrong with the last run.
  final String? error;

  final SettingConfirm deleteConfirm;

  /// What its three buttons are called: "Run Setup", "Import ESBMC", "Delete
  /// Byte Repair Data".
  final String setUpLabel;
  final String importLabel;
  final String deleteLabel;

  final Future<void> Function() _onSetUp;
  final Future<void> Function() _onImport;
  final Future<void> Function() _onDelete;

  Future<void> setUp() => _onSetUp();

  /// Imports a binary the user picks, in place of the one setup fetches.
  Future<void> import() => _onImport();

  /// Called only once [deleteConfirm] has been agreed to.
  Future<void> delete() => _onDelete();
}
