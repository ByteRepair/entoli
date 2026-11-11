import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/controller.dart";
import "../../app/settings/scope.dart";
import "../../app/settings/settings.dart";
import "../../app/settings/spec.dart";
import "../../domain/app_icon.dart";
import "../widgets/app_mark.dart" show AppIconImage;
import "../widgets/choice.dart";
import "../widgets/dialogs.dart";
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
    final found = buildPage(
      WidgetReader(ref),
      ref.watch(settingsSchemaProvider),
      page,
      at,
    ).where((s) => s.spec.id == section).firstOrNull;
    if (found == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(found.spec.title, description: found.description),
        for (final setting in found.settings)
          if (only?.contains(setting.id) ?? true) SettingRow(setting),
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
      final ActionController c => _Action(c),
      final GroupController c => _Group(c),
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
    final footnote = controller.footnote;
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
    UiHint.swatches || UiHint.corners || UiHint.icons => _Looks<T>(c),
    UiHint.levels when c.value != null => LabelledField(
      label: c.title,
      child: ThinkingSlider<T>(
        stops: {for (final o in c.options) o.value: o.label},
        value: c.value as T,
        onChanged: c.set,
        help: c.description,
      ),
    ),
    UiHint.toggle ||
    UiHint.dropdown ||
    UiHint.levels ||
    UiHint.slider ||
    UiHint.keyValues ||
    UiHint.button => _Dropdown<T>(c),
  };
}

/// Says what a change had to say, where it said anything.
Future<void> _tell(BuildContext context, Future<SettingNotice?> change) async {
  final notice = await change;
  if (notice == null || !context.mounted) return;
  await tell(context, title: notice.title ?? "", message: notice.message);
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
    return LabelledField(
      label: c.title,
      child: DropdownButtonFormField<T>(
        initialValue: c.value,
        isExpanded: true,
        decoration: InputDecoration(helperText: c.description),
        items: [
          for (final option in c.options)
            DropdownMenuItem(
              value: option.value,
              enabled: option.enabled,
              child: Text(option.label),
            ),
        ],
        onChanged: c.enabled
            ? (value) {
                if (value != null) _tell(context, c.set(value));
              }
            : null,
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
    AppIconLook(:final icon) => _IconChoice(
      icon: icon,
      tooltip: option.detail ?? option.label,
      selected: selected,
      onTap: onTap,
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

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final AppIcon icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Choice(
    tooltip: tooltip,
    selected: selected,
    onTap: onTap,
    corners: BorderRadius.circular(16),
    width: 104,
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Column(
      children: [
        AppIconImage(icon, size: 48),
        const SizedBox(height: 10),
        Text(icon.label, style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
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

  static IconData? _icon(SettingGlyph? glyph) => switch (glyph) {
    SettingGlyph.deleteForever => Icons.delete_forever,
    null => null,
  };

  Future<void> _press(BuildContext context) async {
    final ask = await c.confirm();
    if (!context.mounted) return;
    if (ask != null) {
      final yes = await confirm(
        context,
        title: ask.title,
        message: ask.message,
        confirmLabel: ask.confirmLabel,
        destructive: ask.destructive,
      );
      if (!yes || !context.mounted) return;
    }
    await _tell(context, c.run());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = _icon(c.glyph);
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

  String _shown(int n) =>
      "${n >= 1000 && n % 1000 == 0 ? "${n ~/ 1000}k" : "$n"}"
      "${c.unit == null ? "" : " ${c.unit}"}";

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
