import "../../core/log.dart";
import "../../data/builtin/memory/store.dart";
import "../../domain/date_words.dart" show shortDate;
import "../../domain/project.dart" show ProjectRef;
import "../../providers.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A memory's age in words: the year goes with it once it is no longer this
/// one, because a memory outlives the week reminders are planned for.
String _when(DateTime at) {
  final day = shortDate(at);
  return at.year == DateTime.now().year ? day : "$day ${at.year}";
}

/// A project's memories: what they are, a search that matches the way a
/// turn's recall does, and adding, pinning and deleting them. A paired
/// device's store is read there, and read only while it is away.
class MemoryAppPage extends AppPage {
  MemoryAppPage({required this.project, required this.owner});

  final ProjectRef project;

  /// Whose memories these are, as the page is titled.
  final String owner;

  List<MemoryEntry>? _entries;
  String _query = "";
  int _generation = 0;
  bool? _wasFrozen;

  Memories get _store => app.read(memoriesProvider(project));

  @override
  String get address =>
      "memory/${project.device ?? ""}/${project.project ?? ""}";

  @override
  void opened() => _reload();

  /// A search types faster than the store answers, and an old answer must
  /// not land under a newer query.
  Future<void> _reload() async {
    final generation = ++_generation;
    List<MemoryEntry> entries;
    try {
      final all = await _store.entries();
      // Newest first as the store holds them read back; a search best first,
      // the order the recall would have offered them in.
      entries = _query.isEmpty
          ? all.reversed.toList()
          : await _store.search(_query);
    } catch (e) {
      // A paired device gone: what was drawn stays.
      logFailure("memory", "could not read memories", e);
      entries = _entries ?? const [];
    }
    if (generation != _generation) return;
    _entries = entries;
    changed();
  }

  @override
  String title(SettingReader reader) => owner;

  @override
  List<PageSection> sections(SettingReader reader) {
    final frozen = reader.watch(projectFrozenProvider(project));
    // Back is read again rather than trusted.
    if (_wasFrozen == true && !frozen) _reload();
    _wasFrozen = frozen;
    final entries = _entries;
    return [
      if (project.device != null)
        notice(
          "device",
          "${reader.watch(syncPeersProvider)[project.device]?.name ?? "The device"} "
              "${frozen ? "is offline; its memories are read only until it is back." : "holds these memories."}",
          tone: frozen ? NoticeTone.warning : NoticeTone.plain,
        ),
      PageSection("search", "", [
        TextController(
          part("search", "Search", hint: UiHint.input),
          value: _query,
          prompt: "Search memories",
          allowBlank: true,
          onSet: (text) async {
            _query = text.trim();
            await _reload();
            return null;
          },
        ),
      ]),
      PageSection("entries", "", [
        if (entries == null)
          NoticeController(
            part("loading", ""),
            lines: const [NoticeLine("Reading the memories…")],
          )
        else
          CollectionController<MemoryEntry>(
            part("entries", "Memories", hint: UiHint.info),
            items: entries,
            enabled: !frozen,
            removable: false,
            emptyLabel: _query.isEmpty
                ? "No memories yet. Facts the agent keeps, and ones you add, "
                      "land here."
                : "Nothing the store holds is about “$_query”.",
            addLabel: frozen ? null : "Add Memory…",
            form: (_) => const _NewMemory(),
            submit: (answers, _) async {
              try {
                await _store.add(answers["text"]!.trim());
              } catch (_) {
                throw const FormRefusal(
                  "text",
                  "The memory could not be saved.",
                );
              }
              await _reload();
            },
            describe: (entry) => CollectionItem(
              entry.text,
              subtitle:
                  "${_when(entry.at)} · "
                  "${entry.chat == null ? "added by you" : "kept by the agent"}",
              badge: entry.pinned ? "Pinned" : null,
              glyph: SettingGlyph.memory,
              editable: false,
              takesImage: false,
              opens: InlinePage(entry.text),
              actions: [
                ItemAction(
                  "pin",
                  entry.pinned ? "Unpin" : "Pin: in Every Turn",
                  enabled: !frozen,
                ),
                ItemAction(
                  "delete",
                  "Delete",
                  destructive: true,
                  enabled: !frozen,
                  confirm: SettingConfirm(
                    title: "Delete memory?",
                    message:
                        "Delete \"${entry.text.length > 80 ? "${entry.text.substring(0, 80)}…" : entry.text}\"?",
                    confirmLabel: "Delete",
                    destructive: true,
                  ),
                ),
              ],
            ),
            act: (index, action) => _act(entries[index], action),
          ),
      ]),
    ];
  }

  Future<SettingNotice?> _act(MemoryEntry entry, String action) async {
    final store = _store;
    try {
      switch (action) {
        case "pin" when entry.pinned:
          await store.unpin(entry.id);
        case "pin":
          // Counted over the whole store: a search is a window, and a pin
          // made inside it must not slip past the limit the full list shows.
          final pinned = (await store.entries()).where((e) => e.pinned).length;
          if (pinned >= pinnedLimit) {
            return const SettingNotice("Four is the most that can be pinned.");
          }
          await store.pin(entry.id);
        case "delete":
          await store.delete(entry.id);
      }
    } catch (_) {
      return SettingNotice(
        action == "delete"
            ? "The memory could not be deleted."
            : "The pin could not be changed.",
      );
    }
    await _reload();
    return null;
  }
}

/// A memory typed in.
class _NewMemory extends SettingForm<MemoryEntry> {
  const _NewMemory();

  @override
  String get title => "New Memory";

  @override
  Map<String, String> get initial => const {"text": ""};

  @override
  List<FormFieldSpec> fields(Map<String, String> answers) => const [
    FormText(
      "text",
      "Memory",
      hint: "A fact worth keeping: a preference, a decision, a learned detail.",
      lines: 4,
      focused: true,
    ),
  ];

  @override
  String? problem(Map<String, String> answers) =>
      (answers["text"] ?? "").trim().isEmpty ? "" : null;

  /// Never asked: the list saves through its own submit.
  @override
  MemoryEntry build(Map<String, String> answers) =>
      throw UnsupportedError("a memory is added by the store");
}
