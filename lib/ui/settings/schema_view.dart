import "../bot_avatar/bot_avatar_view.dart";
import "../widgets/document_view.dart";
import "../widgets/web_view.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/platform/rich_clipboard.dart";
import "../../app/settings/controller.dart";
import "../skills/skill_view.dart";
import "../../domain/bot_avatar/spec.dart";
import "../bot_avatar/bot_avatar_editor.dart";
import "../widgets/agent_picture.dart";
import "../../core/formatting.dart";
import "../../app/settings/scope.dart";
import "../../app/settings/settings.dart";
import "../../app/settings/spec.dart";
import "../../app/settings/pages/about.dart" show madeBy;
import "../app_command.dart";
import "../theme.dart" show appTitle;
import "../widgets/app_mark.dart";
import "privacy_policy_page.dart";
import "rich_rows.dart";
import "../../domain/models.dart" show AttachmentKind;
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/catalog.dart";
import "../widgets/settings_warning_banner.dart";
import "../widgets/page_bar.dart";
import "byte_repair_settings.dart";
import "form_dialog.dart";
import "setting_icons.dart";
import "sync_pairing.dart";
import "../widgets/choice.dart";
import "../widgets/dialogs.dart";
import "../widgets/editable_row.dart";
import "../widgets/environment_section.dart";
import "../widgets/model_picker.dart";
import "../widgets/thinking_slider.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// [page]'s sections at [at], drawn from the schema: each section's header,
/// its settings, and a divider between one section and the next.
class SchemaSections extends ConsumerWidget {
  const SchemaSections(this.page, {super.key, this.at = const AppAddress()});

  final SettingsPageId page;
  final ScopeAddress at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = buildPage(
      WidgetReader(ref),
      ref.watch(settingsSchemaProvider),
      page,
      at,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, section) in sections.indexed) ...[
          if (i > 0) const Divider(),
          if (section.spec.title.isNotEmpty || section.description != null)
            SectionHeader(section.spec.title, description: section.description),
          for (final setting in section.settings) SettingRow(setting),
        ],
      ],
    );
  }
}

/// One of [page]'s sections at [at], alone: a page that shows a part of
/// settings among its own, as the welcome tour does. [only] keeps to those
/// settings where it names any.
class SchemaSection extends ConsumerWidget {
  const SchemaSection(
    this.page,
    this.section, {
    super.key,
    this.at = const AppAddress(),
    this.only,
  });

  final SettingsPageId page;
  final String section;
  final ScopeAddress at;
  final Set<String>? only;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = buildSection(
      WidgetReader(ref),
      ref.watch(settingsSchemaProvider),
      page,
      section,
      at,
      only: only,
    );
    if (found == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(found.spec.title, description: found.description),
        for (final setting in found.settings) SettingRow(setting),
      ],
    );
  }
}

/// One setting, drawn the way its hint asks where this frontend has that
/// way, its kind's own way where it does not.
class SettingRow extends StatelessWidget {
  const SettingRow(this.controller, {super.key, this.nested = false});

  final SettingController controller;

  /// Drawn inside a group, under the group's label rather than its own.
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final field = switch (controller) {
      final ToggleController c => _Toggle(c),
      final ChoiceController c => c.typed(_choice),
      final SlotsController c => c.typed(<V>(c) => _Slots<V>(c)),
      final RangeController c => _Range(c),
      final KeyValuesController c => _KeyValues(c),
      // The loaded models' view draws its own Unload all.
      final ActionController c => _Action(c),
      final GroupController c when c.hint == UiHint.buttons => _Buttons(c),
      final GroupController c when c.hint == UiHint.recommended => _Recommended(
        c,
      ),
      final GroupController c => _Group(c),
      final TextController c => _Text(c),
      final PromptController c => PromptPreview(c),
      final DocumentController c => SizedBox(
        height: 480,
        child: DocumentView(c),
      ),
      final WebController c => SizedBox(height: 480, child: WebPageView(c)),
      final NoticeController c => switch (c.hint) {
        UiHint.banner => _Banner(c),
        UiHint.installed || UiHint.field => LabelledField(
          label: c.title,
          child: Text(c.lines.map((l) => l.text).join("\n")),
        ),
        UiHint.paragraph => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: mutedParagraph(context, c.lines.map((l) => l.text).join("\n")),
        ),
        UiHint.card => _Card(c),
        _ => _Notice(c),
      },
      final CollectionController c when c.hint == UiHint.cards => c.typed(
        <V>(c) => _Cards<V>(c),
      ),
      final CollectionController c => c.typed(<V>(c) => _Collection<V>(c)),
      final PairingController c => PairingControls(flow: c.flow),
      final SubpageController c => ListTile(
        title: Text(c.title),
        subtitle: c.summary == null ? null : Text(c.summary!),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => SchemaPage(c.page))),
      ),
      final CatalogController c when c.hint == UiHint.single => _Single(c),
      final CatalogController c => _Catalog(c),
      final InfoController c => _Info(c),
      final SetupController c => SetupView(c),
      final NumberController c => _Number(c, labelled: !nested),
      final ModelPickController c => LabelledField(
        label: c.title,
        child: ModelPicker(
          choice: c.choice,
          nullLabel: c.nullLabel,
          defaultOf: c.defaultOf,
          inherited: c.inherited,
          role: c.role,
          helperOffText: c.description,
          onChanged: c.set,
        ),
      ),
    };
    // A group, a typed field and a slider that waits for the drag to end say
    // their footnotes inside themselves.
    final footnote = switch (controller) {
      GroupController() => null,
      TextController(hint: UiHint.input) => null,
      RangeController(commitOnEnd: true) => null,
      _ => controller.footnote,
    };
    if (footnote == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(footnote, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  /// A choice's widget, by its hint. The swatch-shaped hints are for
  /// options with looks; one without falls back to a dropdown.
  static Widget _choice<T>(ChoiceController<T> c) => switch (c.hint) {
    UiHint.segmented => _Segmented<T>(c),
    UiHint.swatches || UiHint.corners => _Looks<T>(c),
    // Unset at a level that inherits, it stands where the level above does,
    // with the reset back to it once this level picks.
    UiHint.levels when (c.value ?? c.inherited) != null => LabelledField(
      label: c.title,
      child: switch (ThinkingSlider<T>(
        stops: {for (final o in c.options) o.value: o.label},
        value: (c.value ?? c.inherited) as T,
        onChanged: c.set,
        help: c.description,
      )) {
        final slider when c.unsettable => ResettableField(
          onReset: () => c.set(null),
          resetLabel: c.inheritedLabel ?? defaultOptionLabel,
          child: slider,
        ),
        final slider => slider,
      },
    ),
    // Every other hint is another kind's; a choice is a dropdown.
    _ => _Dropdown<T>(c),
  };
}

/// Runs [c], asking first what it asks: a confirm, a passing note that
/// stops it, or nothing at all where what it opened was dismissed.
Future<void> runSettingAction(BuildContext context, ActionController c) =>
    _run(context, c);

Future<void> _run(BuildContext context, ActionController c) async {
  final ask = await c.confirm();
  if (!context.mounted || !await _agreed(context, ask)) return;
  if (context.mounted) await _tell(context, c.run());
}

/// Whether what [ask] asks was agreed to: a confirm said yes to, or nothing
/// asked; a passing note, or a cancelled ask, is no.
Future<bool> _agreed(BuildContext context, SettingConfirm? ask) async {
  if (ask == null) return true;
  if (ask.cancelled) return false;
  if (ask.brief) {
    say(context, ask.message);
    return false;
  }
  return await confirm(
        context,
        title: ask.title,
        message: ask.message,
        confirmLabel: ask.confirmLabel,
        destructive: ask.destructive,
      ) &&
      context.mounted;
}

/// Says what a change had to say, where it said anything: in a dialog where
/// it has a title, in passing where it does not.
Future<void> _tell(BuildContext context, Future<SettingNotice?> change) async {
  final notice = await change;
  if (notice == null || !context.mounted) return;
  if (notice.copy case final text?) {
    await writeClipboard(ClipboardContent(plain: text));
    if (!context.mounted) return;
  }
  final title = notice.title;
  if (title == null) return say(context, notice.message);
  await tell(context, title: title, message: notice.message);
}

/// A setting's accessory, as the icon button at its end.
Widget? _accessory(BuildContext context, SettingController c) {
  final action = c.accessory;
  if (action == null) return null;
  return IconButton(
    onPressed: action.enabled ? () => _tell(context, action.run()) : null,
    icon: Icon(settingIcon(action.glyph) ?? Icons.more_horiz),
    tooltip: action.label,
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.c);

  final ToggleController c;

  @override
  Widget build(BuildContext context) {
    final subtitle = c.description;
    if (c.unsettable) {
      return InheritableSwitch(
        title: c.title,
        subtitle: subtitle,
        value: c.value,
        inherited: c.effective,
        enabled: c.enabled,
        onChanged: (value) => _tell(context, c.set(value)),
      );
    }
    return SwitchListTile(
      title: Text(c.title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: c.effective,
      onChanged: c.enabled ? (value) => _tell(context, c.set(value)) : null,
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  const _Segmented(this.c);

  final ChoiceController<T> c;

  @override
  Widget build(BuildContext context) => LabelledField(
    label: c.title,
    child: SegmentedButton<T>(
      segments: [
        for (final option in c.options)
          ButtonSegment(
            value: option.value,
            label: Text(option.label),
            enabled: option.enabled,
          ),
      ],
      selected: {?c.value},
      emptySelectionAllowed: c.value == null,
      onSelectionChanged: (picked) => _tell(context, c.set(picked.first)),
    ),
  );
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown(this.c);

  final ChoiceController<T> c;

  @override
  Widget build(BuildContext context) {
    if (c.unsettable) {
      return InheritableDropdown<T>(
        label: c.title,
        value: c.value,
        inherited: c.inheritedLabel,
        options: {for (final o in c.options) o.value: o.label},
        disabled: {
          for (final o in c.options)
            if (!o.enabled) o.value,
        },
        onChanged: (value) => _tell(context, c.set(value)),
      );
    }
    final none = c.noneLabel;
    if ((none != null || c.hint == UiHint.installed) &&
        c is ChoiceController<String>) {
      final strings = c as ChoiceController<String>;
      return InstalledPicker(
        label: c.title,
        none: none,
        description: c.description,
        value: strings.value,
        options: {for (final o in strings.options) o.value: o.label},
        onPick: (value) => _tell(context, strings.set(value)),
      );
    }
    final field = DropdownButtonFormField<T>(
      key: ValueKey(c.value),
      initialValue: c.value,
      isExpanded: true,
      decoration: InputDecoration(
        helperText: c.description,
        helperMaxLines: 3,
        errorText: c.error,
        errorMaxLines: 4,
      ),
      items: [
        for (final option in c.options)
          DropdownMenuItem(
            value: option.value,
            enabled: option.enabled,
            child: Text(option.label),
          ),
      ],
      // Null is an option of its own where the type holds it: the default
      // project is one.
      onChanged: c.enabled
          ? (value) {
              if (value != null || null is T) _tell(context, c.set(value));
            }
          : null,
    );
    final accessory = _accessory(context, c);
    return LabelledField(
      label: c.title,
      child: accessory == null
          ? field
          : Row(
              children: [
                Expanded(child: field),
                accessory,
              ],
            ),
    );
  }
}

/// A labelled row of choices drawn as what they are, wrapping where the
/// window is too narrow for all of them.
class _Looks<T> extends StatelessWidget {
  const _Looks(this.c);

  final ChoiceController<T> c;

  @override
  Widget build(BuildContext context) => LabelledField(
    label: c.title,
    child: Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final option in c.options)
          _LookChoice(
            option,
            selected: option.value == c.value,
            onTap: () => _tell(context, c.set(option.value)),
          ),
      ],
    ),
  );
}

/// One option drawn as its look: a swatch, a corner, an icon.
class _LookChoice extends StatelessWidget {
  const _LookChoice(this.option, {required this.selected, required this.onTap});

  final SettingOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => switch (option.look) {
    final SwatchLook look => _Swatch(
      label: option.label,
      look: look,
      selected: selected,
      onTap: onTap,
    ),
    CornerLook(:final radius) => Choice(
      tooltip: option.label,
      label: option.label,
      selected: selected,
      onTap: onTap,
      corners: BorderRadius.circular(radius),
      fill: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      width: 44,
      height: 44,
    ),
    null => Choice(
      tooltip: option.label,
      label: option.label,
      selected: selected,
      onTap: onTap,
    ),
  };
}

/// A colour as the colour itself: a swatch says what it does and a name in a
/// dropdown would not. A second colour splits it diagonally, a theme being
/// its two seeds.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.look,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final SwatchLook look;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = Color(look.argb);
    final b = Color(look.second ?? look.argb);
    return Choice(
      tooltip: label,
      label: label,
      selected: selected,
      onTap: onTap,
      fill: a,
      gradient: a == b
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [a, a, b, b],
              stops: const [0, 0.5, 0.5, 1],
            ),
      width: 40,
      height: 40,
      // The tick sits on the swatch rather than on the surface, so it is read
      // against the colour it is marking — across a split, against the two
      // mixed, since it straddles the line.
      child: selected
          ? Icon(
              Icons.check,
              size: 18,
              color:
                  ThemeData.estimateBrightnessForColor(
                        Color.lerp(a, b, 0.5)!,
                      ) ==
                      Brightness.dark
                  ? Colors.white
                  : Colors.black,
            )
          : null,
    );
  }
}

/// The slots picked one at a time from one set of options: a switch says
/// which is being picked, and wears each one's current look, so a pair is
/// visible here even though no option below is it.
class _Slots<T> extends StatefulWidget {
  const _Slots(this.c);

  final SlotsController<T> c;

  @override
  State<_Slots<T>> createState() => _SlotsState<T>();
}

class _SlotsState<T> extends State<_Slots<T>> {
  var _slot = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.c;
    final groupStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final selected = c.slots[_slot].value;
    Widget dot(SettingOption slot) => Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: switch (slot.look) {
          SwatchLook(:final argb) => Color(argb),
          _ => null,
        },
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
    );
    return LabelledField(
      label: c.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              for (final (i, slot) in c.slots.indexed)
                ButtonSegment(
                  value: i,
                  icon: dot(slot),
                  label: Text(slot.label),
                ),
            ],
            selected: {_slot},
            onSelectionChanged: (picked) =>
                setState(() => _slot = picked.first),
          ),
          for (final group in c.groups) ...[
            const SizedBox(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.label, style: groupStyle),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final option in group.options)
                      _LookChoice(
                        option,
                        selected: option.value == selected,
                        onTap: () => c.set(_slot, option.value),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Range extends StatelessWidget {
  const _Range(this.c);

  final RangeController c;

  @override
  Widget build(BuildContext context) {
    if (c.commitOnEnd) return _DragSlider(c);
    // A count with no stops and nothing to inherit is a plain slider over
    // every number from the least to the most.
    if (c.stops == null && !c.unsettable) {
      final min = c.min ?? 0;
      final max = c.max ?? min;
      return Slider(
        value: c.effective.clamp(min, max).toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: max > min ? max - min : null,
        label: "${c.effective}",
        onChanged: c.enabled
            ? (value) => _tell(context, c.set(value.round()))
            : null,
      );
    }
    return _stops(context);
  }

  Widget _stops(BuildContext context) => InheritableSlider(
    label: c.title,
    value: c.value,
    stops: c.stops ?? [for (var i = c.min ?? 0; i <= (c.max ?? 0); i++) i],
    inherited: c.inherited,
    onChanged: (value) => _tell(context, c.set(value)),
  );
}

class _KeyValues extends StatelessWidget {
  const _KeyValues(this.c);

  final KeyValuesController c;

  @override
  Widget build(BuildContext context) =>
      EnvironmentRows(env: c.entries, onSaved: c.save);
}

class _Action extends StatelessWidget {
  const _Action(this.c);

  final ActionController c;

  Future<void> _press(BuildContext context) => _run(context, c);

  @override
  Widget build(BuildContext context) {
    if (c.hint == UiHint.open) {
      final description = c.description;
      final icon = settingIcon(c.glyph);
      return ListTile(
        leading: icon == null ? null : Icon(icon),
        title: Text(c.title),
        subtitle: description == null ? null : Text(description),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.label.isNotEmpty) Text(c.label),
            const Icon(Icons.chevron_right),
          ],
        ),
        enabled: c.enabled,
        onTap: () => _press(context),
      );
    }
    if (c.hint == UiHint.permission) {
      final description = c.description;
      return ListTile(
        leading: Icon(settingIcon(c.glyph)),
        title: Text(c.title),
        subtitle: description == null ? null : Text(description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _press(context),
      );
    }
    if (c.hint == UiHint.row) {
      final description = c.description;
      final icon = settingIcon(c.glyph);
      final onPressed = c.enabled ? () => _press(context) : null;
      return ListTile(
        title: Text(c.title),
        subtitle: description == null ? null : Text(description),
        trailing: c.iconOnly && icon != null
            ? IconButton(
                icon: Icon(icon),
                tooltip: c.label,
                onPressed: onPressed,
              )
            : OutlinedButton(onPressed: onPressed, child: Text(c.label)),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final icon = settingIcon(c.glyph);
    final style = c.destructive
        ? FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          )
        : null;
    final onPressed = c.enabled ? () => _press(context) : null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: icon == null
          ? FilledButton(
              style: style,
              onPressed: onPressed,
              child: Text(c.label),
            )
          : FilledButton.icon(
              style: style,
              icon: Icon(icon),
              label: Text(c.label),
              onPressed: onPressed,
            ),
    );
  }
}

/// Settings under one label, and a line saying what they do together.
class _Group extends StatelessWidget {
  const _Group(this.c);

  final GroupController c;

  @override
  Widget build(BuildContext context) {
    final footnote = c.footnote;
    return LabelledField(
      label: c.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final child in c.children)
            if (child.visible) SettingRow(child, nested: true),
          if (footnote != null)
            Text(footnote, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// A count typed in a dialog rather than slid to, with a reset to its
/// default.
class _Number extends StatelessWidget {
  const _Number(this.c, {required this.labelled});

  final NumberController c;
  final bool labelled;

  String _shown(int n) => "${inK(n)}${c.unit == null ? "" : " ${c.unit}"}";

  @override
  Widget build(BuildContext context) {
    final fallback = _shown(c.fallback).split(" ").first;
    final tile = ResettableField(
      onReset: () => c.set(c.fallback),
      resetLabel: "$fallback (default)",
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(_shown(c.value)),
        subtitle: const Text("Tap to change"),
        onTap: c.enabled
            ? () async {
                final text = await promptForText(
                  context,
                  title: c.title,
                  initial: "${c.value}",
                  hint: c.prompt,
                  confirmLabel: "Save",
                );
                if (text == null || !context.mounted) return;
                final parsed = int.tryParse(text.replaceAll(",", "").trim());
                if (parsed == null) return;
                await c.set(parsed);
              }
            : null,
      ),
    );
    return labelled ? LabelledField(label: c.title, child: tile) : tile;
  }
}

/// Text shown on a row, typed in a dialog the row opens.
class _Text extends StatelessWidget {
  const _Text(this.c);

  final TextController c;

  Future<void> _edit(BuildContext context) async {
    final text = await promptForText(
      context,
      title: c.title,
      initial: c.value,
      confirmLabel: "Save",
      hint: c.prompt,
      maxLines: c.lines,
      allowBlank: c.allowBlank,
    );
    if (text == null || !context.mounted) return;
    await _tell(context, c.set(text));
  }

  @override
  Widget build(BuildContext context) {
    final shown = c.value.isEmpty ? c.emptyLabel : c.value;
    final clear = c.clearLabel;
    if (c.hint == UiHint.input) return _Input(c);
    if (c.hint == UiHint.field) {
      final description = c.description;
      return LabelledField(
        label: c.title,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(shown ?? ""),
          subtitle: description == null ? null : Text(description),
          onTap: c.enabled ? () => _edit(context) : null,
          trailing: _accessory(context, c),
        ),
      );
    }
    if (clear == null) {
      return ListTile(
        title: Text(c.title),
        subtitle: shown == null ? null : Text(shown),
        onTap: c.enabled ? () => _edit(context) : null,
      );
    }
    return EditableRow(
      title: c.title,
      subtitle: shown,
      removeLabel: clear,
      onTap: c.enabled ? () => _edit(context) : null,
      onRemove: () => _tell(context, c.set("")),
    );
  }
}

/// Paragraphs to read, then the links they point at.
class _Notice extends ConsumerWidget {
  const _Notice(this.c);

  final NoticeController c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = c.lines.where((l) => l.url != null);
    return Padding(
      // The inset every other block on a page keeps: a paragraph flush to the
      // edge reads as belonging to something else.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in c.lines)
            if (line.url == null) mutedParagraph(context, line.text),
          if (links.isNotEmpty) const SizedBox(height: 8),
          for (final line in links)
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft,
              ),
              onPressed: () =>
                  ref.read(linkOpenerProvider).open(context, line.url!),
              child: Text(line.text),
            ),
        ],
      ),
    );
  }
}

/// A warning line under what it is about.
class _Banner extends StatelessWidget {
  const _Banner(this.c);

  final NoticeController c;

  @override
  Widget build(BuildContext context) => SettingsWarningBanner(
    icon: settingIcon(c.glyph) ?? Icons.info_outline,
    color: _toneColour(context, c.tone),
    text: c.lines.map((l) => l.text).join("\n"),
  );
}

Color _toneColour(BuildContext context, NoticeTone tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    NoticeTone.warning => scheme.error,
    NoticeTone.good || NoticeTone.plain => scheme.primary,
  };
}

/// A line set apart on a card, an icon saying how it stands.
class _Card extends StatelessWidget {
  const _Card(this.c);

  final NoticeController c;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: ListTile(
      leading: Icon(switch (c.tone) {
        NoticeTone.warning => Icons.warning_amber_rounded,
        NoticeTone.good => Icons.shield_outlined,
        NoticeTone.plain => Icons.info_outline,
      }, color: _toneColour(context, c.tone)),
      title: Text(c.lines.map((l) => l.text).join("\n")),
    ),
  );
}

/// One row per thing to download, with the single button that applies to it
/// now.
class _Catalog extends StatelessWidget {
  const _Catalog(this.c);

  final CatalogController c;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final item in c.items)
        CatalogTile(
          title: item.badge == null
              ? Text(item.title)
              : Row(
                  children: [
                    Flexible(child: Text(item.title)),
                    const SizedBox(width: 8),
                    _Badge(
                      label: item.badge!,
                      tone: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
          summary: item.summary,
          tags: item.facts == null ? const [] : modelTags(item.facts!),
          note: item.note,
          failure: item.failure,
          progress: item.progress,
          trailing: CatalogAction(
            downloading: item.progress != null,
            installed: item.installed,
            onCancel: () => c.cancel(item.id),
            onDelete: () => c.delete(item.id),
            deleteTitle: item.deleteConfirm?.title ?? "Delete ${item.title}?",
            deleteMessage: item.deleteConfirm?.message ?? "",
            onDownload: item.downloadable ? () => c.download(item.id) : null,
          ),
        ),
      if (c.addLabel case final add?)
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add_link),
            label: Text(add),
            onPressed: c.add,
          ),
        ),
    ],
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: tone),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone),
    ),
  );
}

/// One thing to download, kept current: its version or why it stopped, the
/// bar while it comes, and Delete beside Update once it is here.
class _Single extends StatelessWidget {
  const _Single(this.c);

  final CatalogController c;

  @override
  Widget build(BuildContext context) =>
      Column(children: [for (final item in c.items) _row(item)]);

  Widget _row(CatalogItem item) {
    final progress = item.progress;
    return ListTile(
      title: Text(item.title),
      subtitle: progress != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  progress.unpacking
                      ? "Installing…"
                      : progress.total > 0
                      ? "Downloading · ${progress.received >> 20} of "
                            "${progress.total >> 20} MB"
                      : "Downloading…",
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: progress.bar),
              ],
            )
          : Text(item.failure ?? item.summary ?? ""),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress != null)
            TextButton(
              onPressed: () => c.cancel(item.id),
              child: const Text("Cancel"),
            )
          else ...[
            if (item.installed)
              IconButton(
                tooltip: "Delete",
                icon: const Icon(Icons.delete_outline),
                onPressed: () => c.delete(item.id),
              ),
            FilledButton.tonal(
              onPressed: item.downloadable ? () => c.download(item.id) : null,
              child: Text(
                item.installed && item.updatable ? "Update" : "Download",
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Rows to read: each with its icon, or its keys, and where it leads.
class _Info extends ConsumerWidget {
  const _Info(this.c);

  final InfoController c;

  void _open(BuildContext context, WidgetRef ref, InfoRow row) {
    if (row.link case final link?) {
      ref.read(linkOpenerProvider).open(context, link);
      return;
    }
    if (row.opens case final page?) openTextPage(context, page);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final row in c.rows)
        if (row.keys case final keys?)
          ListTile(title: Text(row.title), trailing: _Keys(keys.caps))
        else
          ListTile(
            leading: row.glyph == SettingGlyph.appMark
                ? const AppMark(size: 40)
                : settingIcon(row.glyph) == null
                ? null
                : Icon(settingIcon(row.glyph)),
            title: Text(row.title),
            subtitle: row.subtitle == null ? null : Text(row.subtitle!),
            trailing: row.link != null
                ? const Icon(Icons.open_in_new, size: 18)
                : row.opens != null
                ? const Icon(Icons.chevron_right)
                : null,
            onTap: row.link == null && row.opens == null
                ? null
                : () => _open(context, ref, row),
          ),
    ],
  );
}

/// A chord's keys, each on a cap of its own.
class _Keys extends StatelessWidget {
  const _Keys(this.caps);

  final List<String> caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        for (final cap in caps)
          Container(
            constraints: const BoxConstraints(minWidth: 28),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              cap,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium,
            ),
          ),
      ],
    );
  }
}

/// A page of settings of its own, opened from a row: its sections under a
/// bar named for it.
class SchemaPage extends StatelessWidget {
  const SchemaPage(this.page, {super.key, this.at = const AppAddress()});

  final SettingsPageId page;
  final ScopeAddress at;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: PageBar(title: page.title),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [SchemaSections(page, at: at)],
    ),
  );
}

/// Text typed in place, saved as it is typed; a reset beside it where it
/// can be cleared.
class _Input extends StatefulWidget {
  const _Input(this.c);

  final TextController c;

  @override
  State<_Input> createState() => _InputState();
}

class _InputState extends State<_Input> {
  late final _text = TextEditingController(text: widget.c.value);

  @override
  void didUpdateWidget(_Input old) {
    super.didUpdateWidget(old);
    // Set from elsewhere — a page's Clear — rather than typed here; a value
    // still catching up with the typing is left alone.
    final value = widget.c.value;
    if (value != old.c.value && value != _text.text) _text.text = value;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final field = TextFormField(
      controller: _text,
      obscureText: c.secret,
      enabled: c.enabled,
      decoration: InputDecoration(hintText: c.prompt, isDense: true),
      onChanged: (value) => c.set(value),
    );
    final clear = c.clearLabel;
    final footnote = c.footnote;
    final labelled = LabelledField(
      label: c.title,
      child: clear == null
          ? field
          : ResettableField(onReset: () => c.set(""), child: field),
    );
    // A footnote under a field is a paragraph of its own, set in the page's
    // muted voice.
    if (footnote == null) return labelled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        labelled,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: mutedParagraph(context, footnote),
        ),
      ],
    );
  }
}

/// Actions side by side, the first filled and the rest outlined, and the bar
/// that runs while one of them does.
class _Buttons extends StatelessWidget {
  const _Buttons(this.c);

  final GroupController c;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AddButtonRow(
        child: Row(
          spacing: 12,
          children: [
            for (final child in c.children)
              if (child case final ActionController action when action.visible)
                action.secondary
                    ? OutlinedButton.icon(
                        icon: Icon(settingIcon(action.glyph)),
                        label: Text(action.label),
                        onPressed: action.enabled
                            ? () => _run(context, action)
                            : null,
                      )
                    : FilledButton.icon(
                        icon: Icon(settingIcon(action.glyph)),
                        label: Text(action.label),
                        onPressed: action.enabled
                            ? () => _run(context, action)
                            : null,
                      ),
          ],
        ),
      ),
      SizedBox(
        height: 2,
        child: c.busy ? const LinearProgressIndicator(minHeight: 2) : null,
      ),
    ],
  );
}

/// A recommended service while nothing answers: why it, a way to sign up and
/// its policy, and the key to paste where one is already in hand.
class _Recommended extends ConsumerStatefulWidget {
  const _Recommended(this.c);

  final GroupController c;

  @override
  ConsumerState<_Recommended> createState() => _RecommendedState();
}

class _RecommendedState extends ConsumerState<_Recommended> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final why = widget.c.children.whereType<NoticeController>().first;
    final key = widget.c.children.whereType<TextController>().first;
    final text = why.lines.where((l) => l.url == null);
    final links = why.lines.where((l) => l.url != null).toList();
    final hasKey = _key.text.trim().isNotEmpty;
    void open(NoticeLine link) =>
        ref.read(linkOpenerProvider).open(context, link.url!);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in text) Text(line.text),
            const SizedBox(height: 12),
            for (final (i, link) in links.indexed) ...[
              if (i > 0) const SizedBox(height: 4),
              i == 0
                  ? FilledButton(
                      onPressed: () => open(link),
                      child: Text(link.text),
                    )
                  : TextButton(
                      onPressed: () => open(link),
                      child: Text(link.text),
                    ),
            ],
            const Divider(height: 32),
            Text(key.title),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: key.secret,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: key.prompt),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasKey ? () => key.set(_key.text) : null,
              child: Text(key.submitLabel ?? "Save"),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slider written once the drag ends rather than on every pixel, with a
/// reset to what unset means and a line saying where it stands.
class _DragSlider extends StatefulWidget {
  const _DragSlider(this.c);

  final RangeController c;

  @override
  State<_DragSlider> createState() => _DragSliderState();
}

class _DragSliderState extends State<_DragSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final min = c.min ?? 0;
    final max = c.max ?? min;
    final value = _dragging ?? c.effective.toDouble();
    final footnote = c.footnote;
    return LabelledField(
      label: c.title,
      child: ResettableField(
        onReset: () => c.set(null),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Slider(
              value: value.clamp(min.toDouble(), max.toDouble()),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max > min ? max - min : null,
              label: "${value.round()}",
              onChanged: (v) => setState(() => _dragging = v),
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                c.set(v.round());
              },
            ),
            if (footnote != null)
              Text(footnote, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// The items as cards, as many across as the width takes up to three: each
/// its face, name, words and badge, a tap running the item's [tap].
class _Cards<T> extends StatelessWidget {
  const _Cards(this.c);

  final CollectionController<T> c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = c.rows;
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 12.0;
        final inner = box.maxWidth - 32;
        final across = (inner / 280).floor().clamp(1, 3);
        final width = (inner - gap * (across - 1)) / across;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final (index, row) in rows.indexed)
                SizedBox(
                  width: width,
                  child: Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: switch (row.tap) {
                        final tap? => () => _tell(context, c.act(index, tap)),
                        null => null,
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            switch ((row.face, settingIcon(row.glyph))) {
                              (AvatarRowFace(:final spec, :final animate), _) =>
                                BotAvatarView(
                                  spec: spec,
                                  size: 48,
                                  animate: animate,
                                ),
                              (_, final icon?) => SizedBox.square(
                                dimension: 48,
                                child: Icon(
                                  icon,
                                  size: 28,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              _ => const SizedBox.shrink(),
                            },
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    row.title,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  if (row.subtitle case final words?
                                      when words.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        words,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  if (row.badge case final badge?)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        badge,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: theme.colorScheme.primary,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The items as rows, each with what [CollectionItem] says of it: its state
/// at a glance, its words and what went wrong, the switch that arms it, what
/// can be done to it, and a tap that edits it through its form; and the
/// button that adds one.
class _Collection<T> extends StatelessWidget {
  const _Collection(this.c);

  final CollectionController<T> c;

  Future<void> _act(BuildContext context, int index, ItemAction action) async {
    switch (action.kind) {
      case ItemActionKind.photo:
        return _picture(context, index);
      case ItemActionKind.botAvatar:
        return _botAvatar(context, index, c.rows[index]);
      case ItemActionKind.run:
    }
    if (!await _agreed(context, action.confirm) || !context.mounted) return;
    await _tell(context, c.act(index, action.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = c.rows;
    final inline = MediaQuery.sizeOf(context).width >= 600;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rows.isEmpty && c.emptyLabel != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: mutedParagraph(context, c.emptyLabel!),
          ),
        for (final (index, row) in rows.indexed)
          if (c.actionsOf(row) case final actions)
            ListTile(
              leading: switch ((row.face, settingIcon(row.glyph))) {
                (AvatarRowFace(:final spec, :final animate), _) =>
                  BotAvatarView(
                    spec: spec,
                    size: 40,
                    animate: animate,
                    reactToTap: true,
                  ),
                // Live, and happy at a tap: a row scrolled out of view is not
                // painted, which stops its ticker until it is back.
                (AgentRowFace(:final project, :final name), _) => AgentPicture(
                  name: name,
                  project: project,
                  animate: true,
                  reactToTap: true,
                ),
                (null, null) => null,
                (null, final icon?) => Icon(
                  icon,
                  color: switch (row.tone) {
                    NoticeTone.good => Colors.green,
                    NoticeTone.warning => theme.colorScheme.error,
                    NoticeTone.plain => theme.colorScheme.onSurfaceVariant,
                  },
                ),
              },
              title: Text(row.title),
              subtitle: _words(context, row),
              onTap: _tap(context, index, row),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (row.badge case final badge?)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(badge),
                    ),
                  if (row.on case final on?)
                    Switch(value: on, onChanged: (_) => c.act(index, "toggle")),
                  // A few side by side where there is room; more, or a
                  // narrow window, in a menu.
                  if (actions.length <= 3 && inline)
                    for (final action in actions)
                      TextButton(
                        onPressed: action.enabled
                            ? () => _act(context, index, action)
                            : null,
                        style: action.destructive
                            ? TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                              )
                            : null,
                        child: Text(action.label),
                      )
                  else
                    PopupMenuButton<ItemAction>(
                      tooltip: "More",
                      onSelected: (action) => _act(context, index, action),
                      itemBuilder: (_) => [
                        for (final action in actions)
                          PopupMenuItem(
                            value: action,
                            enabled: action.enabled,
                            child: Text(
                              action.label,
                              style: action.destructive
                                  ? TextStyle(color: theme.colorScheme.error)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  if (c.removable)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: row.removeLabel ?? c.removeLabel,
                      onPressed: () => c.remove(index),
                    ),
                ],
              ),
            ),
        if (c.editable && c.addLabel != null)
          AddButtonRow(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: Text(c.addLabel!),
              onPressed: () => editItem(context, c),
            ),
          ),
      ],
    );
  }

  /// A picture picked as the item's, through the app's own picker; anything
  /// but a PNG is refused, a picture being kept as the PNG it was given as.
  Future<void> _picture(BuildContext context, int index) async {
    final picks = await ProviderScope.containerOf(
      context,
    ).read(attachmentPickerProvider).pick(AttachmentKind.image);
    if (picks.isEmpty || !context.mounted) return;
    final pick = picks.single;
    if (!pick.filename.toLowerCase().endsWith(".png")) {
      return say(context, "The picture is saved as a .png — pick a PNG image.");
    }
    await c.setImage(index, pick.bytes);
  }

  /// The avatar editor, opened on the Bot Avatar the item wears where it
  /// wears one, and what was made there put on it.
  Future<void> _botAvatar(
    BuildContext context,
    int index,
    CollectionItem row,
  ) async {
    final worn = switch (row.face) {
      AgentRowFace(:final agent) => await ProviderScope.containerOf(
        context,
      ).read(agentPictureProvider(agent).future),
      _ => null,
    };
    if (!context.mounted) return;
    final spec = await Navigator.of(context).push<BotAvatarSpec>(
      MaterialPageRoute(
        builder: (_) => BotAvatarEditorPage(initial: worn?.bot),
      ),
    );
    if (spec != null) await c.setBotAvatar(index, spec);
  }

  /// What a tap on the row does: edits it through its form, opens its page,
  /// or runs the action it names.
  VoidCallback? _tap(BuildContext context, int index, CollectionItem row) {
    if (c.editable && row.editable) {
      return () => editItem(context, c, index: index);
    }
    if (row.opens case final page?) {
      return () => openTextPage(context, page);
    }
    final tap = row.tap;
    if (tap == null) return null;
    // A tap need not be in the row's menu: opening a folder is the row itself.
    final listed = row.actions.where((a) => a.id == tap).firstOrNull;
    return () => _act(context, index, listed ?? ItemAction(tap, row.title));
  }

  Widget? _words(BuildContext context, CollectionItem row) {
    final error = row.error;
    if (row.subtitle == null && error == null && row.meters.isEmpty) {
      return null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (row.subtitle case final subtitle?) Text(subtitle),
        if (error != null)
          SelectableText(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final meter in row.meters)
          if (meter.segments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SegmentedMeter(meter),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(meter.text),
                  if (meter.fraction case final fraction?) ...[
                    const SizedBox(height: 2),
                    LinearProgressIndicator(
                      value: fraction,
                      semanticsLabel: meter.text,
                    ),
                  ],
                ],
              ),
            ),
      ],
    );
  }
}

/// Opens [page] over the settings.
void openTextPage(BuildContext context, TextPage page) => switch (page) {
  PolicyPage() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyPage())),
  LicencesPage() => showLicensePage(
    context: context,
    applicationName: appTitle,
    applicationVersion: ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appVersionProvider),
    applicationIcon: const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: AppMark(size: 48),
    ),
    applicationLegalese: madeBy,
  ),
  InlinePage(:final text) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(text),
        ),
      ),
    ),
  ),
  SkillPage(:final name, :final project, :final origin) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SkillViewPage(name: name, project: project, origin: origin),
      ),
    ),
};
