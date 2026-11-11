import "../../app/settings/forms/model.dart"
    show modelFormFor, pickerProviders, saveModel;
import "../../app/settings/spec.dart" show WidgetReader;
import "../settings/form_dialog.dart";
import "../../app/model_facts.dart" show providerHue;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/hosted_models.dart";
import "../../data/builtin/llm/providers/provider.dart" show LlmProvider;
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "../../domain/local_model.dart" show isTitleOnlyModel;
import "../../domain/model_capability.dart";
import "../../domain/model_registry.dart";
import "../../app/model_role.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../../core/formatting.dart";
import "../fonts.dart";
import "catalog.dart" show InfoTag;
import "dialogs.dart" show confirm;
import "page_bar.dart";

export "../../app/model_role.dart";

/// One model a picker can offer, with the provider it is reached through.
class CatalogEntry {
  const CatalogEntry(
    this.providerId,
    this.providerName,
    this.info, {
    this.custom = false,
  });

  final String providerId;
  final String providerName;
  final ModelInfo info;

  /// Added by hand rather than listed by models.dev.
  final bool custom;

  ModelRef get ref => (providerId: providerId, modelId: info.id);
}

/// What a picker offers: each provider's models that [role] can use — the
/// on-device one's, then the configured ones' from the catalog — then whatever
/// the endpoints list that the catalog does not know, a self-hosted server's
/// models.
List<CatalogEntry> catalogEntries(
  ModelCatalog catalog,
  List<LlmProvider> providers,
  List<ModelOption> listed, {
  required ModelRole role,
  ModelHost? host,
}) {
  host ??= ModelHost.resolving();
  // Same-named models — one model through two providers — keep the order the
  // providers are configured in.
  final order = {for (final (i, p) in providers.indexed) p.id: i};
  final described = [
    for (final p in providers)
      for (final m in p.offered(catalog, host)) (provider: p, model: m),
  ];
  // Every model a provider describes, whatever this role makes of it: what
  // the catalog says of one wins over the endpoint naming it.
  final known = {for (final d in described) (d.provider.id, d.model.info.id)};
  final shown = <(String, String)>{};
  return [
    for (final (:provider, :model) in described)
      if (role.offers(model) && shown.add((provider.id, model.info.id)))
        CatalogEntry(
          provider.id,
          provider.displayName,
          model.info,
          custom: provider.config.customModels.any(
            (c) => c.id == model.info.id,
          ),
        ),
    // Named by their own listing — `<endpoint> · <model>` — and taken to be
    // chat models, since nothing says otherwise: no image model is guessed.
    if (role.chat)
      for (final o in listed)
        if (!known.contains((o.providerId, o.modelId)) &&
            (role == ModelRole.title ||
                !isTitleOnlyModel(o.providerId, o.modelId)))
          _listedEntry(o),
  ]..sort((a, b) {
    final byName = a.info.displayName.toLowerCase().compareTo(
      b.info.displayName.toLowerCase(),
    );
    return byName != 0
        ? byName
        : (order[a.providerId] ?? order.length).compareTo(
            order[b.providerId] ?? order.length,
          );
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

  // Rebuilt only when what it is built from changes, not on every keystroke.
  // Records compare their fields with ==, which is identity for the lists.
  Object? _entriesKey;
  var _entries = const <CatalogEntry>[];

  List<CatalogEntry> _entriesOf(
    ModelCatalog catalog,
    List<LlmProvider> providers,
    List<ModelOption> listed,
    bool cutsUtterances,
  ) {
    final key = (catalog, providers, listed, cutsUtterances);
    if (key != _entriesKey) {
      _entriesKey = key;
      _entries = catalogEntries(
        catalog,
        providers,
        listed,
        role: widget.role,
        host: ModelHost.resolving(cutsUtterances: cutsUtterances),
      );
    }
    return _entries;
  }

  bool _matches(CatalogEntry e, List<String> words) {
    final hay = "${e.info.displayName} ${e.info.id} ${e.providerName}"
        .toLowerCase();
    return words.every(hay.contains) &&
        (!_reasoning || e.info.reasoning) &&
        (!_seesImages || e.info.readsImages) &&
        (_provider == null || e.providerId == _provider);
  }

  bool _picked(String? providerId, String? modelId) =>
      widget.choice.providerId == providerId &&
      widget.choice.modelId == modelId;

  void _pick(String? providerId, String? modelId) => Navigator.of(
    context,
  ).pop<ModelChoice>((providerId: providerId, modelId: modelId));

  /// Adds a model, or edits [initial] on [provider].
  Future<void> _openModelPage({String? provider, ModelInfo? initial}) async {
    final reader = WidgetReader(ref);
    final form = modelFormFor(
      reader,
      widget.role,
      providerId: provider,
      model: initial?.id,
    );
    if (form == null) return;
    String? saved;
    await showSettingForm(
      context,
      form,
      save: (answers) async {
        await saveModel(reader, form, answers);
        saved = answers["id"]!.trim();
      },
    );
    // Found straight away, since it is what was just described.
    if (saved case final id? when mounted) setState(() => _search.text = id);
  }

  Future<void> _addModel() => _openModelPage(provider: _provider);

  Future<void> _deleteModel(CatalogEntry entry) async {
    final settings = ref.read(appSettingsProvider.notifier);
    final ok = await confirm(
      context,
      title: "Delete ${entry.info.displayName}?",
      message:
          "It is no longer offered for ${entry.providerName}. A model "
          "already picked keeps its id until another is picked.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (ok) await settings.removeCustomModel(entry.providerId, entry.info.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Drawn again as the providers change.
    ref.watch(appSettingsProvider.select((s) => s.llmProviders));
    final cutsUtterances = ref.watch(voiceProvider).hasModelCatalog;
    final providers = pickerProviders(WidgetReader(ref), widget.role);
    final listed =
        ref.watch(sortedModelsProvider).value ?? const <ModelOption>[];
    final serving = ref.watch(modelProvidersProvider);
    return ValueListenableBuilder(
      valueListenable: ModelCatalog.notifier,
      builder: (context, catalog, _) {
        final all = _entriesOf(catalog, serving, listed, cutsUtterances);
        final words = _search.text.toLowerCase().split(RegExp(r"\s+"))
          ..removeWhere((w) => w.isEmpty);
        final shown = all.where((e) => _matches(e, words)).toList();
        final names = {
          for (final p in providers) p.id: p.displayName,
          for (final e in all) e.providerId: e.providerName,
        }..removeWhere((id, _) => !all.any((e) => e.providerId == id));
        final searching = _search.text.isNotEmpty;
        final favourites = ref.watch(
          appSettingsProvider.select((s) => s.favouriteModels),
        );
        // In the order they were starred, which is the order they were wanted.
        final starred = [
          for (final f in favourites) ?all.where((e) => e.ref == f).firstOrNull,
        ];
        return Scaffold(
          appBar: PageBar(
            title: "Choose ${widget.role.article} ${widget.role.noun}",
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(112),
              child: _Readable(
                Padding(
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
                            _Filter(
                              "Reasoning",
                              Icons.psychology_alt_outlined,
                              _reasoning,
                              (v) => setState(() => _reasoning = v),
                            ),
                            if (widget.role.chat)
                              _Filter(
                                "Sees images",
                                Icons.image_search,
                                _seesImages,
                                (v) => setState(() => _seesImages = v),
                              ),
                            if (names.length > 1)
                              for (final MapEntry(key: id, value: name)
                                  in names.entries)
                                _Filter(
                                  name,
                                  Icons.cloud_outlined,
                                  _provider == id,
                                  (v) =>
                                      setState(() => _provider = v ? id : null),
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
          floatingActionButton: providers.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _addModel,
                  icon: const Icon(Icons.add),
                  label: const Text("Add model"),
                ),
          body: _Readable(
            CustomScrollView(
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
                          subtitle: const Text(
                            "The full catalog comes from models.dev "
                            "and arrives the next time Entoli is online.",
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!searching) ...[
                  _header(theme, "Quick picks"),
                  SliverList.list(
                    children: [
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
                    ],
                  ),
                ],
                if (!searching && starred.isNotEmpty) ...[
                  _header(theme, "Favourites"),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverList.list(
                      children: [for (final e in starred) _card(e, favourites)],
                    ),
                  ),
                ],
                _header(
                  theme,
                  shown.length == 1 ? "1 model" : "${shown.length} models",
                ),
                if (shown.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _Empty(
                      role: searching ? null : widget.role,
                      onAdd: providers.isEmpty ? null : _addModel,
                    ),
                  )
                else
                  SliverPadding(
                    // Room under the last card for the button floating over it.
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                    sliver: SliverList.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _card(shown[i], favourites),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _card(CatalogEntry e, List<ModelRef> favourites) => _ModelCard(
    entry: e,
    selected: _picked(e.providerId, e.info.id),
    favourite: favourites.contains(e.ref),
    onTap: () => _pick(e.providerId, e.info.id),
    onStar: () => ref.read(appSettingsProvider.notifier).toggleFavourite(e.ref),
    manage: e.custom
        ? (
            edit: () => _openModelPage(provider: e.providerId, initial: e.info),
            delete: () => _deleteModel(e),
          )
        : null,
  );

  Widget _header(ThemeData theme, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
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
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: child,
    ),
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
  const _ModelCard({
    required this.entry,
    required this.selected,
    required this.favourite,
    required this.onTap,
    required this.onStar,
    this.manage,
  });

  final CatalogEntry entry;
  final bool selected;
  final bool favourite;
  final VoidCallback onTap;
  final VoidCallback onStar;

  /// Where it was added by hand: the user's to change, and nobody else's.
  final ({VoidCallback edit, VoidCallback delete})? manage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = entry.info;
    final price = modelPrice(info.inputCost, info.outputCost);
    // The theme's corners with an outline of our own: the app's card shape
    // replaces the outlined card's, border and all.
    final base = theme.cardTheme.shape is OutlinedBorder
        ? theme.cardTheme.shape! as OutlinedBorder
        : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : scheme.surface,
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
                        Text(
                          info.displayName,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          "${entry.providerName} · ${info.id}",
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFamily: monoFamily,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (selected) Icon(Icons.check_circle, color: scheme.primary),
                  IconButton(
                    tooltip: favourite
                        ? "Remove from favourites"
                        : "Add to favourites",
                    isSelected: favourite,
                    icon: const Icon(Icons.star_border),
                    selectedIcon: Icon(Icons.star, color: scheme.primary),
                    onPressed: onStar,
                  ),
                  if (manage case final manage?)
                    PopupMenuButton<VoidCallback>(
                      tooltip: "Model options",
                      onSelected: (action) => action(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: manage.edit,
                          child: const Text("Edit"),
                        ),
                        PopupMenuItem(
                          value: manage.delete,
                          child: const Text("Delete"),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (info.context != null)
                    InfoTag(
                      Icons.data_usage,
                      "${tokenCount(info.context!)} context",
                    ),
                  if (price != null) InfoTag(Icons.payments_outlined, price),
                  if (info.toolCall) InfoTag(Icons.build_outlined, "Tools"),
                  if (info.reasoning)
                    InfoTag(Icons.psychology_alt_outlined, "Reasoning"),
                  if (info.readsImages)
                    InfoTag(Icons.image_search, "Sees images"),
                  if (info.makesImages)
                    InfoTag(Icons.brush_outlined, "Makes images"),
                  if (info.transcribes) InfoTag(Icons.hearing, "Transcribes"),
                  if (info.speaks)
                    InfoTag(Icons.record_voice_over_outlined, "Speaks"),
                  if (entry.custom)
                    InfoTag(Icons.edit_outlined, "Added by you"),
                ],
              ),
            ],
          ),
        ),
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
    final hue = providerHue(name).toDouble();
    final bg = HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.28 : 0.86).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.5, dark ? 0.86 : 0.28).toColor();
    return CircleAvatar(
      radius: 18,
      backgroundColor: bg,
      child: Text(
        name.isEmpty ? "?" : name.characters.first.toUpperCase(),
        style: TextStyle(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.role, required this.onAdd});

  /// The picker with nothing to offer at all, null while searching. For a
  /// media role that is most often a provider without such models rather than
  /// a model missing from the list.
  final ModelRole? role;
  final VoidCallback? onAdd;

  String? get _media => role?.emptyNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.travel_explore,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            _media != null ? "No ${role!.noun}s" : "No model matches",
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            onAdd == null && role?.voice != true
                ? "Add a provider in Settings > Providers to see its models."
                : _media ??
                      "Not every model is in the catalog. A fine-tune or a "
                          "private deployment can be added by hand.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
