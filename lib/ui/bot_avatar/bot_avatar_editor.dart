import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/definition.dart";
import "../../domain/bot_avatar/import.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../providers.dart";
import "../fonts.dart";
import "../widgets/dialogs.dart";
import "../widgets/page_bar.dart";
import "bot_avatar_view.dart";
import "colour_dialog.dart";

/// The spec an import is held to. The prompt a model designs one with is the
/// marketplace's `bot-avatar-creator` skill.
final _spec = Uri.parse(
  "https://dominikscholz.github.io/open-bot-avatar/#/docs",
);

/// One shape the editor offers, and where it came from.
class BotAvatarEntry {
  const BotAvatarEntry(this.definition, this.ownColour, this.source);

  final BotAvatarDefinition definition;

  /// The colour it shows until one is picked for it, and what Reset
  /// returns it to.
  final int ownColour;

  final BotAvatarSource source;

  /// Tells entries apart: an import may share a preset's id.
  String get key => "${source.name}:${definition.id}";
}

enum BotAvatarSource {
  /// Shipped with the app.
  preset,

  /// Pasted in on the Import tab; removable.
  imported,

  /// What the agent wore when the editor opened, where that is neither —
  /// an import since deleted, say.
  current,
}

/// Choose and colour the Bot Avatar an agent wears. The live preview stands
/// over the controls on a tall screen and beside them on a wide one; the
/// controls are two tabs — **Bots**, every preset and import in its own
/// colour over a bar of colours for the chosen one, and **Import**, where a
/// definition a model wrote is pasted in. An import joins the Bots tab and
/// leaves it by a long press or a right click.
///
/// Choosing, it pops the [BotAvatarSpec] chosen, or null where the page was
/// closed. [BotAvatarEditorPage.browse] is the same page with nothing to
/// choose for — opened from the agents list to look through the avatars and
/// import or delete them — so it has no Use and goes back rather than
/// closing.
class BotAvatarEditorPage extends ConsumerStatefulWidget {
  const BotAvatarEditorPage({super.key, this.initial}) : choosing = true;

  const BotAvatarEditorPage.browse({super.key})
    : initial = null,
      choosing = false;

  /// What the agent wears now, selected as the page opens.
  final BotAvatarSpec? initial;

  /// For an agent: Use pops the one chosen.
  final bool choosing;

  @override
  ConsumerState<BotAvatarEditorPage> createState() =>
      _BotAvatarEditorPageState();
}

class _BotAvatarEditorPageState extends ConsumerState<BotAvatarEditorPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);
  final _paste = TextEditingController();
  late final _specLink = TapGestureRecognizer()
    ..onTap = () => ref.read(linkOpenerProvider).open(context, _spec);

  /// The chosen entry's key; null takes the first entry there is.
  String? _selected;

  /// Colours picked this visit, by entry key.
  final _colours = <String, int>{};
  var _mood = BotMood.idle;
  BotAvatarImport? _import;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      // Selected wherever it turns out to be; coloured as it was.
      _selected = "?:${initial.definition.id}";
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _paste.dispose();
    _specLink.dispose();
    super.dispose();
  }

  List<BotAvatarEntry> _entries() {
    final presets = ref.watch(botAvatarPresetsProvider).value ?? const [];
    final imported = ref.watch(importedBotAvatarsProvider).value ?? const [];
    final entries = [
      for (final p in presets)
        BotAvatarEntry(p.definition, p.colour, BotAvatarSource.preset),
      for (final d in imported)
        BotAvatarEntry(d, BotPalette.ownColour(d.id), BotAvatarSource.imported),
    ];
    final initial = widget.initial;
    if (initial != null &&
        !entries.any((e) => e.definition == initial.definition)) {
      entries.insert(
        0,
        BotAvatarEntry(
          initial.definition,
          initial.colour,
          BotAvatarSource.current,
        ),
      );
    }
    return entries;
  }

  /// The selected entry: by key, or — for the one the page opened on — by
  /// its definition, which is what an agent's spec carries.
  BotAvatarEntry? _current(List<BotAvatarEntry> entries) {
    if (entries.isEmpty) return null;
    final initial = widget.initial;
    if (_selected == "?:${initial?.definition.id}" && initial != null) {
      final match = entries.firstWhere(
        (e) => e.definition == initial.definition,
        orElse: () => entries.first,
      );
      _selected = match.key;
      _colours.putIfAbsent(match.key, () => initial.colour);
    }
    return entries.firstWhere(
      (e) => e.key == _selected,
      orElse: () => entries.first,
    );
  }

  int _colourOf(BotAvatarEntry entry) => _colours[entry.key] ?? entry.ownColour;

  BotAvatarSpec _specOf(BotAvatarEntry entry) =>
      BotAvatarSpec(definition: entry.definition, colour: _colourOf(entry));

  Future<void> _pickCustom(BotAvatarEntry entry) async {
    final rgb = await showBotColourDialog(context, _colourOf(entry));
    if (rgb != null && mounted) setState(() => _colours[entry.key] = rgb);
  }

  Future<void> _menu(BotAvatarEntry entry, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: "delete",
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text("Delete ${entry.definition.name}"),
          ),
        ),
      ],
    );
    if (choice != "delete" || !mounted) return;
    await ref
        .read(importedBotAvatarsProvider.notifier)
        .remove(entry.definition.id);
    if (!mounted) return;
    setState(() {
      if (_selected == entry.key) _selected = null;
      _colours.remove(entry.key);
    });
    say(context, "Deleted ${entry.definition.name}.");
  }

  Future<void> _runImport() async {
    final result = BotAvatarImport.parse(_paste.text);
    setState(() => _import = result);
    if (result is! BotAvatarImported) return;
    await ref.read(importedBotAvatarsProvider.notifier).add(result.definitions);
    if (!mounted) return;
    final last = result.definitions.last;
    setState(() {
      _selected = "${BotAvatarSource.imported.name}:${last.id}";
      _colours.remove(_selected);
      _paste.clear();
    });
    _tabs.animateTo(0);
    say(
      context,
      result.definitions.length == 1
          ? "Imported ${last.name}."
          : "Imported ${result.definitions.length} avatars.",
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final current = _current(entries);
    return Scaffold(
      appBar: PageBar(
        title: widget.choosing ? "Bot Avatar" : "Bot Avatars",
        leading: widget.choosing ? PageLeading.close : PageLeading.back,
        actions: [
          if (widget.choosing)
            PageAction.text(
              label: "Use",
              prominent: true,
              onPressed: current == null
                  ? null
                  : () => Navigator.of(context).pop(_specOf(current)),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // Beside on a landscape screen, above on a portrait one: one
            // Flex, the direction the only difference.
            final wide = box.maxWidth > box.maxHeight;
            return Flex(
              direction: wide ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  flex: wide ? 5 : 4,
                  child: current == null
                      ? const Center(child: CircularProgressIndicator())
                      : _stage(current),
                ),
                if (wide)
                  const VerticalDivider(width: 1)
                else
                  const Divider(height: 1),
                Flexible(flex: 6, child: _controls(entries, current)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _stage(BotAvatarEntry current) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Center(
                child: BotAvatarView(
                  key: ValueKey(current.key),
                  spec: _specOf(current),
                  size: (box.biggest.shortestSide * 0.85).clamp(48, 420),
                  mood: _mood,
                  followPointer: true,
                  turnable: true,
                ),
              ),
            ),
          ),
          Text(current.definition.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<BotMood>(
            showSelectedIcon: false,
            segments: [
              for (final mood in BotMood.values)
                ButtonSegment(value: mood, label: Text(mood.label)),
            ],
            selected: {_mood},
            onSelectionChanged: (picked) =>
                setState(() => _mood = picked.single),
          ),
        ],
      ),
    );
  }

  Widget _controls(List<BotAvatarEntry> entries, BotAvatarEntry? current) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: "Bots"),
            Tab(text: "Import"),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [_bots(entries, current), _importTab()],
          ),
        ),
      ],
    );
  }

  Widget _bots(List<BotAvatarEntry> entries, BotAvatarEntry? current) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GridView.extent(
            maxCrossAxisExtent: 76,
            padding: const EdgeInsets.all(12),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final entry in entries)
                _cell(entry, selected: entry.key == current?.key),
            ],
          ),
        ),
        if (current != null) ...[const Divider(height: 1), _swatches(current)],
      ],
    );
  }

  Widget _cell(BotAvatarEntry entry, {required bool selected}) {
    final theme = Theme.of(context);
    final removable = entry.source == BotAvatarSource.imported;
    return Tooltip(
      message: removable
          ? "${entry.definition.name} — yours"
          : entry.definition.name,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onLongPressStart: removable
            ? (d) => _menu(entry, d.globalPosition)
            : null,
        onSecondaryTapUp: removable
            ? (d) => _menu(entry, d.globalPosition)
            : null,
        child: Material(
          color: selected
              ? theme.colorScheme.secondaryContainer
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: selected
                ? BorderSide(color: theme.colorScheme.primary, width: 2)
                : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _selected = entry.key),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: FittedBox(
                child: BotAvatarView.thumbnail(
                  spec: _specOf(entry),
                  semanticLabel: entry.definition.name,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _swatches(BotAvatarEntry current) {
    final theme = Theme.of(context);
    final colour = _colourOf(current);
    final own = current.ownColour;
    final ownName = BotPalette.nameOf(own) ?? hexColour(own);
    final custom = BotPalette.nameOf(colour) == null;
    Widget dot({
      required String tip,
      required VoidCallback? onTap,
      required bool on,
      Color? fill,
      Gradient? gradient,
      Widget? child,
    }) => Tooltip(
      message: tip,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            gradient: gradient,
            border: Border.all(
              color: on
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: on ? 3 : 1,
            ),
          ),
          child: child,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final s in BotPalette.all)
            dot(
              tip: s.rgb == own ? "${s.name} (default)" : s.name,
              on: colour == s.rgb,
              fill: Color(0xff000000 | s.rgb),
              onTap: () => setState(() => _colours[current.key] = s.rgb),
            ),
          dot(
            tip: custom ? "Custom ${hexColour(colour)}" : "Custom colour",
            on: custom,
            fill: custom ? Color(0xff000000 | colour) : null,
            gradient: custom
                ? null
                : const SweepGradient(
                    colors: [
                      Colors.red,
                      Colors.yellow,
                      Colors.green,
                      Colors.cyan,
                      Colors.blue,
                      Colors.purple,
                      Colors.red,
                    ],
                  ),
            onTap: () => _pickCustom(current),
          ),
          IconButton(
            icon: const Icon(Icons.replay),
            tooltip: "Reset to its own colour, $ownName",
            onPressed: colour == own
                ? null
                : () => setState(() => _colours.remove(current.key)),
          ),
        ],
      ),
    );
  }

  Widget _importTab() {
    final theme = Theme.of(context);
    final result = _import;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: "Import new looks using the "),
              TextSpan(
                text: "Open Bot Avatar",
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
                recognizer: _specLink,
              ),
              const TextSpan(
                text:
                    " spec. Add the bot-avatar-creator skill from the Entoli "
                    "marketplace to let Entoli make one for you.",
              ),
            ],
          ),
          style: muted,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _paste,
          minLines: 6,
          maxLines: 14,
          style: const TextStyle(fontFamily: monoFamily, fontSize: 13),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText:
                '{\n  "version": 1,\n  "id": "box",\n  "name": "Box",\n'
                '  "body": { "path": "M20 20 H80 V80 H20 Z" },\n'
                '  "eyes": { "x": 50, "y": 46, "spacing": 15, "scale": 1 }\n}',
          ),
          onChanged: (_) {
            if (_import != null) setState(() => _import = null);
          },
        ),
        const SizedBox(height: 12),
        Row(
          spacing: 12,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.download_done),
              label: const Text("Import"),
              onPressed: _runImport,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.content_paste),
              label: const Text("Paste"),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = data?.text;
                if (text != null && mounted) {
                  setState(() {
                    _paste.text = text;
                    _import = null;
                  });
                }
              },
            ),
          ],
        ),
        if (result case BotAvatarImportFailed(:final errors, :final hints)) ...[
          const SizedBox(height: 16),
          for (final e in errors)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                e,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          for (final h in hints) Text("• $h", style: muted),
        ],
        if (result != null && result.notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final n in result.notes) Text(n, style: muted),
        ],
      ],
    );
  }
}
