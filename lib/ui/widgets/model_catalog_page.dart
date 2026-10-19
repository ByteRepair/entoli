import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/llm_provider.dart";
import "../../domain/model_registry.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../fonts.dart";

/// One model a picker can offer, with the provider it is reached through.
class CatalogEntry {
  const CatalogEntry(this.providerId, this.providerName, this.info, {this.custom = false});

  final String providerId;
  final String providerName;
  final ModelInfo info;

  /// Added by hand rather than listed by models.dev.
  final bool custom;
}

/// What a picker's model is for, which decides what it is offered.
enum ModelRole {
  /// Answers turns, which the agent does through tools: only models that call
  /// them.
  agent,

  /// A background completion — a title, a classifier verdict, a memory pass —
  /// which needs only text in and text out.
  text,

  /// Answers `image_generation`: only models that make images.
  image;

  bool offers(ModelInfo m) => switch (this) {
        agent => m.answersTurns,
        text => m.talks,
        image => m.makesImages,
      };
}

/// What a picker offers: each configured provider's models from the catalog
/// that [role] can use, and the on-device ones, whose metadata the app keeps
/// itself.
List<CatalogEntry> catalogEntries(
  ModelCatalog catalog,
  List<LlmProviderConfig> providers,
  List<ModelOption> listed, {
  required ModelRole role,
}) {
  final configured = {for (final p in providers) p.id};
  // Same-named models — one model through two providers — keep the order the
  // providers are configured in.
  final order = {for (final (i, p) in providers.indexed) p.id: i};
  return [
    for (final p in providers)
      for (final m in catalog.modelsOf(p))
        if (role.offers(m))
          CatalogEntry(p.id, p.displayName, m,
              custom: p.customModels.any((c) => c.id == m.id)),
    // The on-device endpoints, named by their own listing — `<endpoint> ·
    // <model>` — and no image model runs there.
    if (role != ModelRole.image)
      for (final o in listed)
        if (!configured.contains(o.providerId))
          _listedEntry(o),
  ]..sort((a, b) {
      final byName =
          a.info.displayName.toLowerCase().compareTo(b.info.displayName.toLowerCase());
      return byName != 0
          ? byName
          : (order[a.providerId] ?? order.length).compareTo(order[b.providerId] ?? order.length);
    });
}

CatalogEntry _listedEntry(ModelOption o) {
  final parts = (o.label ?? o.modelId).split(" · ");
  return CatalogEntry(
    o.providerId,
    parts.length > 1 ? parts.first : o.providerId,
    ModelInfo(id: o.modelId, name: parts.last, toolCall: true),
  );
}

/// Where a picker field goes when tapped: every model the role can use, to
/// search and compare, above the entries that store less than a model — the
/// null entry and each provider's Default. Pops with the [ModelChoice] picked.
class ModelCatalogPage extends ConsumerStatefulWidget {
  const ModelCatalogPage({
    super.key,
    required this.choice,
    required this.nullEntry,
    required this.defaultOf,
    required this.role,
  });

  final ModelChoice choice;

  /// What the entry storing nothing reads as, inherited model included.
  final String nullEntry;
  final String? Function(LlmProviderConfig) defaultOf;
  final ModelRole role;

  @override
  ConsumerState<ModelCatalogPage> createState() => _ModelCatalogPageState();
}

class _ModelCatalogPageState extends ConsumerState<ModelCatalogPage> {
  final _search = TextEditingController();
  var _reasoning = false;
  var _seesImages = false;
  String? _provider;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(CatalogEntry e) {
    final words = _search.text.toLowerCase().split(RegExp(r"\s+")).where((w) => w.isNotEmpty);
    final hay = "${e.info.displayName} ${e.info.id} ${e.providerName}".toLowerCase();
    return words.every(hay.contains) &&
        (!_reasoning || e.info.reasoning) &&
        (!_seesImages || e.info.readsImages) &&
        (_provider == null || e.providerId == _provider);
  }

  bool _picked(String? providerId, String? modelId) =>
      widget.choice.providerId == providerId && widget.choice.modelId == modelId;

  void _pick(String? providerId, String? modelId) =>
      Navigator.of(context).pop<ModelChoice>((providerId: providerId, modelId: modelId));

  Future<void> _addModel() async {
    final added = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => AddModelPage(role: widget.role, provider: _provider),
    ));
    // Found straight away, since it is what was just described.
    if (added != null) setState(() => _search.text = added);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providers = ref.watch(appSettingsProvider.select((s) => s.llmProviders));
    final listed = ref.watch(sortedModelsProvider).value ?? const <ModelOption>[];
    return ValueListenableBuilder(
      valueListenable: ModelCatalog.notifier,
      builder: (context, catalog, _) {
        final all = catalogEntries(catalog, providers, listed, role: widget.role);
        final shown = all.where(_matches).toList();
        final names = {
          for (final p in providers) p.id: p.displayName,
          for (final e in all) e.providerId: e.providerName,
        }..removeWhere((id, _) => !all.any((e) => e.providerId == id));
        final searching = _search.text.isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.role == ModelRole.image ? "Choose an image model" : "Choose a model"),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(112),
              child: _Readable(Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  children: [
                    SearchBar(
                      controller: _search,
                      autoFocus: true,
                      hintText: "Search ${all.length} models",
                      leading: const Icon(Icons.search),
                      trailing: [
                        if (searching)
                          IconButton(
                            tooltip: "Clear",
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(_search.clear),
                          ),
                      ],
                      elevation: const WidgetStatePropertyAll(0),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _Filter("Reasoning", Icons.psychology_alt_outlined, _reasoning,
                              (v) => setState(() => _reasoning = v)),
                          if (widget.role != ModelRole.image)
                            _Filter("Sees images", Icons.image_search, _seesImages,
                                (v) => setState(() => _seesImages = v)),
                          if (names.length > 1)
                            for (final MapEntry(key: id, value: name) in names.entries)
                              _Filter(name, Icons.cloud_outlined, _provider == id,
                                  (v) => setState(() => _provider = v ? id : null)),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
            ),
          ),
          floatingActionButton: providers.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _addModel,
                  icon: const Icon(Icons.add),
                  label: const Text("Add model"),
                ),
          body: _Readable(CustomScrollView(
            slivers: [
              if (catalog.fetched == null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Card.filled(
                      color: theme.colorScheme.secondaryContainer,
                      child: ListTile(
                        leading: const Icon(Icons.cloud_off_outlined),
                        title: const Text("Only the default models for now"),
                        subtitle: const Text("The full catalog comes from models.dev "
                            "and arrives the next time Entoli is online."),
                      ),
                    ),
                  ),
                ),
              if (!searching) ...[
                _header(theme, "Quick picks"),
                SliverList.list(children: [
                  _QuickPick(
                    icon: Icons.block,
                    title: widget.nullEntry,
                    selected: _picked(null, null),
                    onTap: () => _pick(null, null),
                  ),
                  for (final p in providers)
                    if (widget.defaultOf(p) case final id?)
                      _QuickPick(
                        icon: Icons.auto_awesome,
                        title: "${p.displayName} - Default",
                        subtitle: modelInfoOf(p, id)?.displayName ?? id,
                        selected: _picked(p.id, null),
                        onTap: () => _pick(p.id, null),
                      ),
                ]),
              ],
              _header(theme, shown.length == 1 ? "1 model" : "${shown.length} models"),
              if (shown.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Empty(
                      images: widget.role == ModelRole.image && !searching,
                      onAdd: providers.isEmpty ? null : _addModel),
                )
              else
                SliverPadding(
                  // Room under the last card for the button floating over it.
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                  sliver: SliverList.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final e = shown[i];
                      return _ModelCard(
                        entry: e,
                        selected: _picked(e.providerId, e.info.id),
                        onTap: () => _pick(e.providerId, e.info.id),
                      );
                    },
                  ),
                ),
            ],
          )),
        );
      },
    );
  }

  Widget _header(ThemeData theme, String text) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(text,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary)),
        ),
      );
}

/// A list of cards is read down, not across: on a wide window it keeps a
/// column's width in the middle rather than stretching each card edge to edge.
class _Readable extends StatelessWidget {
  const _Readable(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: child),
      );
}

class _Filter extends StatelessWidget {
  const _Filter(this.label, this.icon, this.selected, this.onSelected);

  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          avatar: selected ? null : Icon(icon, size: 18),
          label: Text(label),
          selected: selected,
          onSelected: onSelected,
        ),
      );
}

class _QuickPick extends StatelessWidget {
  const _QuickPick({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: selected
            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
            : null,
        selected: selected,
        onTap: onTap,
      );
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.entry, required this.selected, required this.onTap});

  final CatalogEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = entry.info;
    final price = _price(info);
    // The theme's corners with an outline of our own: the app's card shape
    // replaces the outlined card's, border and all.
    final base = theme.cardTheme.shape is OutlinedBorder
        ? theme.cardTheme.shape! as OutlinedBorder
        : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : scheme.surface,
      shape: base.copyWith(
        side: selected
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Monogram(entry.providerName),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(info.displayName,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text("${entry.providerName} · ${info.id}",
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant, fontFamily: monoFamily),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (selected) Icon(Icons.check_circle, color: scheme.primary),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (info.context != null)
                    _Tag(Icons.data_usage, "${tokenCount(info.context!)} context"),
                  if (price != null) _Tag(Icons.payments_outlined, price),
                  if (info.toolCall) _Tag(Icons.build_outlined, "Tools"),
                  if (info.reasoning) _Tag(Icons.psychology_alt_outlined, "Reasoning"),
                  if (info.readsImages) _Tag(Icons.image_search, "Sees images"),
                  if (info.makesImages) _Tag(Icons.brush_outlined, "Makes images"),
                  if (entry.custom) _Tag(Icons.edit_outlined, "Added by you"),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Per million tokens, in and out, the way providers quote it.
  static String? _price(ModelInfo info) {
    final (input, output) = (info.inputCost, info.outputCost);
    if (input == null && output == null) return null;
    if ((input ?? 0) == 0 && (output ?? 0) == 0) return "Free";
    return "\$${_dollars(input ?? 0)} in · \$${_dollars(output ?? 0)} out /M";
  }

  static String _dollars(double v) {
    final text = v.toStringAsFixed(v < 0.1 ? 3 : 2);
    return text.contains(".") ? text.replaceFirst(RegExp(r"\.?0+$"), "") : text;
  }
}

/// "200K", "1M": a window as providers write it.
String tokenCount(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    return "${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)}M";
  }
  return n >= 1000 ? "${(n / 1000).round()}K" : "$n";
}

class _Tag extends StatelessWidget {
  const _Tag(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// The provider's initial on a colour of its own, so a long list reads by
/// provider at a glance.
class _Monogram extends StatelessWidget {
  const _Monogram(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // A hue of its own per provider, from its name's characters rather than
    // `hashCode`, which is not the same from one run to the next.
    final hue = (name.codeUnits.fold(0, (a, c) => a * 31 + c) % 360).toDouble();
    final bg = HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.28 : 0.86).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.5, dark ? 0.86 : 0.28).toColor();
    return CircleAvatar(
      radius: 18,
      backgroundColor: bg,
      child: Text(name.isEmpty ? "?" : name.characters.first.toUpperCase(),
          style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.images, required this.onAdd});

  /// The image picker with nothing to offer at all, which is most often a
  /// provider that makes no images rather than a model missing from the list.
  final bool images;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.travel_explore, size: 48, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(images ? "No image models" : "No model matches",
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            onAdd == null
                ? "Add a provider in Settings > Providers to see its models."
                : images
                    ? "None of your providers makes images. OpenAI and "
                        "OpenRouter do: add one in Settings > Providers."
                    : "Not every model is in the catalog. A fine-tune or a "
                        "private deployment can be added by hand.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (onAdd != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text("Add model"),
            ),
          ],
        ],
      ),
    );
  }
}

/// A model models.dev does not list, described by hand: the same fields the
/// catalog reads, for the user to fill in. Pops with the new model's id.
class AddModelPage extends ConsumerStatefulWidget {
  const AddModelPage({super.key, required this.role, this.provider});

  /// The picker this was opened from: the toggles start where its models'
  /// would be.
  final ModelRole role;

  /// The provider the catalog was narrowed to, where it was.
  final String? provider;

  @override
  ConsumerState<AddModelPage> createState() => _AddModelPageState();
}

class _AddModelPageState extends ConsumerState<AddModelPage> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _context = TextEditingController();
  final _output = TextEditingController();
  final _inputCost = TextEditingController();
  final _outputCost = TextEditingController();
  late String? _provider = widget.provider;
  late var _toolCall = widget.role == ModelRole.agent;
  var _reasoning = false;
  var _readsImages = false;
  late var _makesImages = widget.role == ModelRole.image;

  @override
  void dispose() {
    for (final c in [_id, _name, _context, _output, _inputCost, _outputCost]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final id = _id.text.trim();
    String? text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    await ref.read(appSettingsProvider.notifier).addCustomModel(
          _provider!,
          ModelInfo(
            id: id,
            name: text(_name),
            context: int.tryParse(text(_context) ?? ""),
            output: int.tryParse(text(_output) ?? ""),
            inputCost: double.tryParse(text(_inputCost) ?? ""),
            outputCost: double.tryParse(text(_outputCost) ?? ""),
            toolCall: _toolCall,
            reasoning: _reasoning,
            readsImages: _readsImages,
            makesImages: _makesImages,
          ),
        );
    if (mounted) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providers = ref.watch(appSettingsProvider.select((s) => s.llmProviders));
    _provider ??= providers.firstOrNull?.id;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Add model"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: const Text("Save")),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              "For a model models.dev does not list: a fine-tune, a private "
              "deployment. Entoli trusts what you enter here, so take it from "
              "the provider's documentation.",
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: "Provider"),
              items: [
                for (final p in providers)
                  DropdownMenuItem(value: p.id, child: Text(p.displayName)),
              ],
              onChanged: (v) => setState(() => _provider = v),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _id,
              decoration: const InputDecoration(
                labelText: "Model id",
                helperText: "Exactly as the provider's API names it",
              ),
              style: const TextStyle(fontFamily: monoFamily),
              validator: (v) => (v ?? "").trim().isEmpty ? "Required" : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: "Display name (optional)"),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _number(_context, "Context window", "tokens")),
                const SizedBox(width: 12),
                Expanded(child: _number(_output, "Max output", "tokens")),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _number(_inputCost, "Input price", "\$ per M tokens", decimal: true)),
                const SizedBox(width: 12),
                Expanded(child: _number(_outputCost, "Output price", "\$ per M tokens", decimal: true)),
              ],
            ),
            const SizedBox(height: 24),
            Text("What it can do", style: theme.textTheme.titleSmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Tool calling"),
              subtitle: _required(theme, _toolCall),
              value: _toolCall,
              onChanged: (v) => setState(() => _toolCall = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Reasoning"),
              value: _reasoning,
              onChanged: (v) => setState(() => _reasoning = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Sees images"),
              subtitle: const Text("Images are sent to it rather than named"),
              value: _readsImages,
              onChanged: (v) => setState(() => _readsImages = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("Makes images"),
              value: _makesImages,
              onChanged: (v) => setState(() => _makesImages = v),
            ),
            if (widget.role == ModelRole.image && !_makesImages)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  "It will not be offered as an image model unless it makes images.",
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Said whatever the switch reads, so it is known before it matters; in the
  /// error colour while it is off, since the model is then not offered as a
  /// chat's model — a title or memory model needs no tools.
  Widget _required(ThemeData theme, bool on) => Text(
        "Required for agentic use: without it, the model is not offered for chats",
        style: on ? null : TextStyle(color: theme.colorScheme.error),
      );

  Widget _number(TextEditingController c, String label, String suffix,
          {bool decimal = false}) =>
      TextFormField(
        controller: c,
        decoration: InputDecoration(labelText: label, helperText: suffix),
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [
          FilteringTextInputFormatter.allow(decimal ? RegExp(r"[0-9.]") : RegExp(r"[0-9]")),
        ],
        validator: (v) => (v ?? "").isEmpty ||
                (decimal ? double.tryParse(v!) : int.tryParse(v!)) != null
            ? null
            : "Not a number",
      );
}
