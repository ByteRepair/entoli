import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../domain/project_settings.dart";
import "../../providers.dart";
import "../widgets/nav_drawer.dart";
import "chat_groups.dart";
import "sidebar.dart";

/// What picking a row does. Run by whoever opened the palette, with its own
/// context and ref: the palette's are disposed by the time the pick lands, and
/// the drawer a picked chat should close is the opener's.
typedef PaletteAction = FutureOr<void> Function(BuildContext context, WidgetRef ref);

/// The project switcher: the whole screen on a phone, a box in the middle of
/// anything wider.
Future<void> showProjectPalette(BuildContext context, WidgetRef ref) async {
  final compact = MediaQuery.sizeOf(context).width < compactWidth;
  final action = await showDialog<PaletteAction>(
    context: context,
    builder: (_) => compact
        ? const Dialog.fullscreen(child: ProjectPalette(compact: true))
        : Dialog(
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
              child: const ProjectPalette(),
            ),
          ),
  );
  if (action == null || !context.mounted) return;
  try {
    await action(context, ref);
  } catch (e) {
    logFailure("palette", "a pick did not go through", e);
  }
}

/// The icon a project's row and the sidebar's switcher show: a built-in's own,
/// else one for the default project and one for the user's.
IconData projectGlyph(String? project) =>
    projectIcon(project) ??
    (project == null ? Icons.home_outlined : Icons.folder_outlined);

const remoteGlyph = Icons.devices_outlined;

/// What the new-project page hands back. A blank description is left unset,
/// which is the default question rather than none at all.
typedef _NewProjectAnswer = ({String name, String description, bool omada});

/// Made on the device the sidebar is showing, which may be a paired one.
PaletteAction _createProject(_NewProjectAnswer answer, String? device) =>
    (context, ref) async {
      if (device != null) {
        final description = answer.description.trim();
        if (!await ref.read(syncHubProvider).createRemoteProject(device, answer.name,
            settings: answer.omada || description.isNotEmpty
                ? ProjectSettings(
                    omada: answer.omada,
                    description: description.isEmpty ? null : description)
                : null)) {
          throw StateError("${answer.name} was not made on $device");
        }
        selectProject(ref, (device: device, project: answer.name));
        return;
      }
      await ref.read(chatRepositoryProvider).createProject(answer.name);
      final settings = ref.read(projectSettingsProvider(answer.name).notifier);
      if (answer.omada) await settings.setOmada(true);
      if (answer.description.trim().isNotEmpty) {
        await settings.setDescription(answer.description.trim());
      }
      ref.invalidate(projectListProvider);
      selectProject(ref, localProject(answer.name));
    };

const _listPage = "list";
const _newPage = "new";

sealed class _Item {
  const _Item();
}

class _Heading extends _Item {
  const _Heading(this.text);
  final String text;
}

class _Rule extends _Item {
  const _Rule();
}

class _Choice extends _Item {
  const _Choice({required this.build, required this.action});

  /// The row, told whether it is the one the arrow keys are on.
  final Widget Function(bool active) build;
  final PaletteAction action;
}

class ProjectPalette extends ConsumerStatefulWidget {
  const ProjectPalette({super.key, this.compact = false});

  /// Full screen, so it carries its own way out.
  final bool compact;

  @override
  ConsumerState<ProjectPalette> createState() => _ProjectPaletteState();
}

class _ProjectPaletteState extends ConsumerState<ProjectPalette> {
  final TextEditingController _search = TextEditingController();
  final GlobalKey _activeKey = GlobalKey();
  String _query = "";

  /// The new-project page is showing in place of the list. Back from it is
  /// back to the list, not out of the palette.
  bool _creating = false;

  /// Which choice the arrow keys are on, counting choices only. Null until a
  /// key or a query moves it, and then the row of the scope being shown.
  int? _active;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (_search.text == _query) return;
      setState(() {
        _query = _search.text;
        _active = _query.isEmpty ? null : 0;
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(PaletteAction action) => Navigator.of(context).pop(action);

  void _move(int by, int count, int current) {
    if (count == 0) return;
    setState(() => _active = (current + by).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _activeKey.currentContext;
      if (row == null) return;
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: by > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_creating,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _creating = false);
      },
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [...previous, ?current],
          ),
          // The new-project page sits to the right of the list. The outgoing
          // child runs its animation backwards, so keying the side on the
          // child alone slides both pages the same way in either direction.
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween(
              begin: Offset(child.key == const ValueKey(_newPage) ? 1 : -1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
          child: _creating
              ? _NewProject(
                  key: const ValueKey(_newPage),
                  omadaByDefault: ref.watch(appSettingsProvider).omadaByDefault,
                  onBack: () => setState(() => _creating = false),
                  // Made before the palette goes, so the page can say it is
                  // waiting on a paired device.
                  onCreate: (answer) async {
                    await _createProject(
                        answer, ref.read(selectedProjectProvider).device)(context, ref);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                )
              : KeyedSubtree(key: const ValueKey(_listPage), child: _list(context)),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final selected = ref.watch(selectedProjectProvider);
    final selectedChat = ref.watch(selectedChatIdProvider);
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final chats = (ref.watch(chatListProvider).value ?? const <ChatState>[])
        .where((c) => !c.isExpired())
        .toList();
    final remotes = remoteEntries(ref.watch(remoteChatsProvider),
        ref.watch(deviceProjectsProvider), ref.watch(syncPeersProvider));
    final running = ref.watch(busyChatsProvider);

    return ValueListenableBuilder<Set<String>>(
      valueListenable: running,
      builder: (context, runningIds, _) {
        final counts = <String?, int>{};
        final busy = <String?>{};
        for (final chat in chats) {
          counts[chat.project] = (counts[chat.project] ?? 0) + 1;
          if (runningIds.contains(chat.id)) busy.add(chat.project);
        }

        _Choice local(String? p) => _Choice(
              build: (active) => _Row(
                active: active,
                current: selected == localProject(p),
                running: busy.contains(p),
                icon: projectGlyph(p),
                label: projectLabel(p),
                omada: ref.watch(omadaOnProvider(p)),
                trailing: _Count(counts[p] ?? 0),
              ),
              action: (_, ref) => selectProject(ref, localProject(p)),
            );
        _Choice mirrored(RemoteEntry e) => _Choice(
              build: (active) => _Row(
                active: active,
                current: e.scope == selected,
                running: false,
                icon: remoteGlyph,
                label: e.label,
                omada: e.omada,
                trailing: _Count(e.count),
              ),
              action: (_, ref) => selectProject(ref, e.scope),
            );

        final needle = searchNeedle(_query);
        final items = <_Item>[];
        int? current;
        if (needle.isEmpty) {
          final every = everyProject(named);
          final builtIn = every.where((p) => !isUserProject(p));
          final mine = every.where(isUserProject);
          var index = 0;
          for (final p in builtIn) {
            if (selected == localProject(p)) current = index;
            items.add(local(p));
            index++;
          }
          items.add(const _Rule());
          for (final p in mine) {
            if (selected == localProject(p)) current = index;
            items.add(local(p));
            index++;
          }
          if (remotes.isNotEmpty) {
            items.add(const _Heading("Other devices"));
            for (final e in remotes) {
              if (e.scope == selected) current = index;
              items.add(mirrored(e));
              index++;
            }
          }
        } else {
          final projects = [
            for (final p in everyProject(named))
              if (projectLabel(p).toLowerCase().contains(needle)) local(p),
            for (final e in remotes)
              if (e.label.toLowerCase().contains(needle)) mirrored(e),
          ];
          if (projects.isNotEmpty) {
            items
              ..add(const _Heading("Projects"))
              ..addAll(projects);
          }
        }

        final found = chatsByRecency(chatsMatching(chats, _query), runningIds);
        if (found.isNotEmpty) {
          if (items.isNotEmpty) items.add(const _Rule());
          for (final chat in found) {
            items.add(_Choice(
              build: (active) => _Row(
                active: active,
                current: chat.id == selectedChat,
                running: runningIds.contains(chat.id),
                label: chat.title.orUntitled,
                trailing: _ProjectTag(projectLabel(chat.project)),
              ),
              // Into its project first: the sidebar lists one project, and
              // a chat it does not list would be open with nothing saying so.
              action: (context, ref) {
                selectProject(ref, localProject(chat.project));
                openChat(context, ref, chat.id);
              },
            ));
          }
        }

        final choices = items.whereType<_Choice>().toList();
        final active = (_active ?? current ?? 0)
            .clamp(0, choices.isEmpty ? 0 : choices.length - 1);
        return Column(
          children: [
            _header(context, choices, active),
            const Divider(height: 1),
            Expanded(
              child: choices.isEmpty
                  ? const Center(child: Text("Nothing matches that."))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _rows(items, choices, active),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  // A column rather than a lazy list: the arrow keys scroll the active row
  // into view, which a row never built cannot be.
  List<Widget> _rows(List<_Item> items, List<_Choice> choices, int active) {
    final theme = Theme.of(context);
    var index = 0;
    return [
      for (final item in items)
        switch (item) {
          _Heading(:final text) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Text(
                text,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _Rule() => const Divider(indent: 16, endIndent: 16),
          _Choice() => () {
              final i = index++;
              return InkWell(
                key: i == active ? _activeKey : null,
                onTap: () => _pick(item.action),
                child: item.build(i == active),
              );
            }(),
        },
    ];
  }

  Widget _header(BuildContext context, List<_Choice> choices, int active) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          if (widget.compact)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: "Close",
              onPressed: () => Navigator.of(context).pop(),
            ),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _move(1, choices.length, active),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _move(-1, choices.length, active),
              },
              child: TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) {
                  if (choices.isNotEmpty) _pick(choices[active].action);
                },
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  hintText: "Search projects and chats",
                  prefixIcon: const Icon(Icons.search, size: 20),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("New Project"),
            onPressed: () => setState(() => _creating = true),
          ),
        ],
      ),
    );
  }
}

/// Running chats first, then the rest; most recently touched first in each.
List<ChatState> chatsByRecency(Iterable<ChatState> chats, Set<String> running) =>
    chats.toList()
      ..sort((a, b) {
        final byRunning = (running.contains(b.id) ? 1 : 0) -
            (running.contains(a.id) ? 1 : 0);
        return byRunning != 0 ? byRunning : b.updatedAt.compareTo(a.updatedAt);
      });

/// The default project and the built-ins sit above the rule, the user's
/// below it.
bool isUserProject(String? project) => project != null && isProjectName(project);

class _Row extends StatelessWidget {
  const _Row({
    required this.active,
    required this.current,
    required this.running,
    required this.label,
    this.icon,
    this.omada = false,
    this.trailing,
  });

  /// Where the arrow keys are.
  final bool active;

  /// What the sidebar is showing.
  final bool current;

  final bool running;
  final IconData? icon;
  final String label;
  final bool omada;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: current
            ? scheme.secondaryContainer
            : active
                ? scheme.onSurface.withValues(alpha: 0.08)
                : null,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          // Reserved whether or not a turn runs, so a turn starting or ending
          // does not move the row.
          SizedBox.square(
            dimension: 16,
            child: running
                ? const CircularProgressIndicator(strokeWidth: 2)
                : null,
          ),
          const SizedBox(width: 12),
          if (icon != null) ...[
            Icon(icon, size: 20),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: current ? scheme.onSecondaryContainer : null,
              ).merge(projectLabelStyle(omada)),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      "$count",
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

class _ProjectTag extends StatelessWidget {
  const _ProjectTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// The new-project page, in the palette's place.
class _NewProject extends StatefulWidget {
  const _NewProject({
    super.key,
    required this.omadaByDefault,
    required this.onBack,
    required this.onCreate,
  });

  final bool omadaByDefault;
  final VoidCallback onBack;
  final Future<void> Function(_NewProjectAnswer) onCreate;

  @override
  State<_NewProject> createState() => _NewProjectState();
}

class _NewProjectState extends State<_NewProject> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _description = TextEditingController();
  late bool _omada = widget.omadaByDefault;

  /// [projectNameFrom]'s answer is the only name that leaves.
  String? get _dir => projectNameFrom(_name.text);

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool _making = false;

  Future<void> _submit() async {
    final dir = _dir;
    if (dir == null || _making) return;
    setState(() => _making = true);
    try {
      await widget.onCreate(
          (name: dir, description: _description.text, omada: _omada));
    } catch (e) {
      logFailure("palette", "could not create $dir", e);
      if (!mounted) return;
      setState(() => _making = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("The project could not be created.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dir = _dir;
    // Said only where it differs from what was typed, which is the case
    // worth knowing about: it is the directory and what the agent sees.
    final renamed = dir != null && dir != _name.text.trim();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: "Back",
                onPressed: widget.onBack,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text("New project", style: theme.textTheme.titleLarge),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: "Name",
                  border: const OutlineInputBorder(),
                  helperText: renamed ? "Saved as $dir" : null,
                  errorText: _name.text.trim().isNotEmpty && dir == null
                      ? "Not a name a project can have"
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _description,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: "Description",
                  hintText: defaultEmptyChatQuestion,
                  helperText: "What a new chat in this project asks.",
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("Team chats (Omada)"),
                subtitle: const Text(
                    "Several named agents take part in this project's chats."),
                value: _omada,
                onChanged: (value) => setState(() => _omada = value),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: dir == null || _making ? null : _submit,
              child: _making
                  ? const SizedBox.square(
                      dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text("Create"),
            ),
          ),
        ),
      ],
    );
  }
}
