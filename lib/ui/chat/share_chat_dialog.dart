import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:share_plus/share_plus.dart";

import "../../app/chat_shares.dart";
import "package:entoli_core/model/formatting.dart" show formatSize;
import "package:entoli_core/model/log.dart";
import "package:entoli_core/store/chat_share.dart"
    show ChatShareSource, ShareFile;
import "package:entoli_core/model/chat_share.dart";
import "package:entoli_core/model/link_bytes.dart" show appLinkMaxLength;
import "package:entoli_core/model/chat_store.dart" show attachmentFilename;
import "package:entoli_core/model/models.dart";
import "package:entoli_core/view/widgets/dialogs.dart"
    show copyToClipboard, say;
import "../widgets/palette_dialog.dart";
import "../widgets/search_field.dart";

/// Share on a chat: which of its files go with it, then the system's share
/// sheet with the link. Framed as the project palette is.
Future<void> showShareChat(
  BuildContext context,
  ChatState chat, {
  Rect? origin,
}) async {
  final link = await showPaletteDialog<String>(
    context,
    (compact) => ShareChatDialog(chat: chat, compact: compact),
  );
  if (link == null || !context.mounted) return;
  await _shareLink(context, link, origin: origin);
}

/// The share sheet where the platform has one. Linux's share_plus opens a
/// `mailto:`, which a 100K link does not survive, so it copies.
Future<void> _shareLink(BuildContext context, String link, {Rect? origin}) {
  if (Platform.isLinux) {
    return copyToClipboard(context, link, said: "Share link copied");
  }
  return SharePlus.instance
      .share(ShareParams(uri: Uri.parse(link), sharePositionOrigin: origin))
      .then<void>((_) {})
      .catchError((Object e) {
        logFailure("share", "the share sheet did not open", e);
        if (context.mounted) {
          return copyToClipboard(context, link, said: "Share link copied");
        }
      });
}

/// The dialog's choices, and what it pops with: the link to share.
class ShareChatDialog extends ConsumerStatefulWidget {
  const ShareChatDialog({super.key, required this.chat, this.compact = false});

  final ChatState chat;
  final bool compact;

  @override
  ConsumerState<ShareChatDialog> createState() => _ShareChatDialogState();
}

/// One entry of the list: a line, or what parts the sections.
sealed class _Item {
  const _Item();
}

final class _Divider extends _Item {
  const _Divider();
}

final class _Heading extends _Item {
  const _Heading(this.text);

  final String text;
}

/// One line of the list, the one the arrow keys move between: a file, or
/// the line ticking every chat attachment at once.
sealed class _Line extends _Item {
  const _Line();
}

final class _Row extends _Line {
  const _Row(this.file, {required this.section, required this.label});

  final ShareFile file;
  final ShareSection section;
  final String label;
}

final class _AllAttachmentsLine extends _Line {
  const _AllAttachmentsLine();
}

class _ShareChatDialogState extends ConsumerState<ShareChatDialog> {
  final _search = TextEditingController();
  ChatShareSource? _source;
  Map<ShareSection, List<_Row>>? _rows;
  final SharePicks _picked = {
    for (final section in ShareSection.values) section: <String>{},
  };

  /// What the zip costs bare, and what each ticked piece adds: measured
  /// once each, everything ticked meanwhile together.
  int? _base;
  final Map<(ShareSection, String), int> _costs = {};
  final Set<(ShareSection, String)> _toMeasure = {};
  bool _measuring = false;

  bool _attachmentsOpen = false;
  int _active = 0;
  bool _packing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() => _active = 0));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final shares = ref.read(chatSharesProvider);
    final ChatShareSource source;
    final Map<ShareSection, List<_Row>> rows;
    try {
      source = await shares.source(widget.chat);
      final candidates = await source.candidates();
      final titles = await shares.artifactTitles(widget.chat);
      String label(ShareSection section, ShareFile file) => switch (section) {
        ShareSection.attachments => attachmentFilename(file.path),
        ShareSection.artifacts => titles[file.path] ?? file.path,
        ShareSection.workspace => file.folder ? "${file.path}/" : file.path,
      };
      rows = {
        for (final MapEntry(key: section, value: files) in candidates.entries)
          section: [
            for (final file in files)
              _Row(file, section: section, label: label(section, file)),
          ],
      };
    } catch (e) {
      logFailure("share", "listing a chat's files failed", e);
      if (mounted) {
        setState(() => _rows = {for (final s in ShareSection.values) s: []});
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _source = source;
      _rows = rows;
      for (final row in rows.values.expand((r) => r)) {
        if (row.file.suggested) _pick(row);
      }
    });
    try {
      final base = await source.base();
      if (mounted) setState(() => _base = base);
    } catch (e) {
      logFailure("share", "measuring a chat failed", e);
      if (mounted) setState(() => _error = "Could not read this chat: $e");
    }
  }

  bool _isPicked(_Row row) => _picked[row.section]!.contains(row.file.path);

  /// Ticks [row], measuring it the first time it is ticked. The measure
  /// waits a microtask, so whatever else is ticked meanwhile goes with it.
  void _pick(_Row row) {
    _picked[row.section]!.add(row.file.path);
    final key = (row.section, row.file.path);
    if (!_costs.containsKey(key) && _toMeasure.add(key)) {
      scheduleMicrotask(_measureNext);
    }
  }

  /// Measures everything ticked since the last measure, in one go.
  Future<void> _measureNext() async {
    final source = _source;
    if (_measuring || _toMeasure.isEmpty || source == null) return;
    _measuring = true;
    final batch = [..._toMeasure];
    try {
      final costs = await source.measure(batch);
      if (!mounted) return;
      setState(() {
        _costs.addAll(costs);
        // Unmeasurable is unpackable: untick it rather than wait on it.
        for (final (section, id) in batch) {
          if (!costs.containsKey((section, id))) _picked[section]!.remove(id);
        }
      });
    } catch (e) {
      logFailure("share", "measuring shared files failed", e);
      if (mounted) {
        setState(() {
          for (final (section, id) in batch) {
            _picked[section]!.remove(id);
          }
        });
      }
    } finally {
      _toMeasure.removeAll(batch);
      _measuring = false;
    }
    _measureNext();
  }

  void _toggle(_Row row) => setState(() {
    _isPicked(row) ? _picked[row.section]!.remove(row.file.path) : _pick(row);
  });

  List<_Row> _rowsIn(ShareSection section) => _rows?[section] ?? const [];

  /// Every attachment ticked, none, or some: the all-attachments line's box.
  bool? get _attachmentsTicked {
    final all = _rowsIn(ShareSection.attachments);
    final ticked = all.where(_isPicked).length;
    return ticked == 0 ? false : (ticked == all.length ? true : null);
  }

  void _toggleAttachments() => setState(() {
    final all = _rowsIn(ShareSection.attachments);
    if (_attachmentsTicked ?? false) {
      _picked[ShareSection.attachments]!.clear();
    } else {
      all.forEach(_pick);
    }
  });

  /// How the ticks fit, or null while something ticked is still measured.
  ShareFit? get _fit {
    final base = _base;
    if (base == null) return null;
    for (final MapEntry(key: section, value: ids) in _picked.entries) {
      if (ids.any((id) => !_costs.containsKey((section, id)))) return null;
    }
    return shareFit(
      base: base,
      picks: _picked,
      cost: (section, id) => _costs[(section, id)]!,
    );
  }

  String get _query => _search.text.trim().toLowerCase();

  List<_Row> _matching(ShareSection section) => _rowsIn(section)
      .where((r) => _query.isEmpty || r.label.toLowerCase().contains(_query))
      .toList();

  /// What the list draws, in order, and the lines among it. A search opens
  /// the attachments to show which of them match; a divider parts them from
  /// the rest.
  (List<_Item>, List<_Line>) get _entries {
    final items = <_Item>[];
    final lines = <_Line>[];
    for (final section in ShareSection.values) {
      final rows = _matching(section);
      if (rows.isEmpty) continue;
      if (section == ShareSection.attachments) {
        items.add(const _AllAttachmentsLine());
        lines.add(const _AllAttachmentsLine());
        if (!_attachmentsOpen && _query.isEmpty) continue;
      } else {
        if (lines.firstOrNull is _AllAttachmentsLine &&
            !items.any((i) => i is _Heading)) {
          items.add(const _Divider());
        }
        items.add(
          _Heading(
            section == ShareSection.artifacts ? "Artifacts" : "Workspace",
          ),
        );
      }
      items.addAll(rows);
      lines.addAll(rows);
    }
    return (items, lines);
  }

  void _toggleLine(_Line line) => switch (line) {
    _Row() => _toggle(line),
    _AllAttachmentsLine() => _toggleAttachments(),
  };

  Future<void> _share() async {
    final fit = _fit;
    final source = _source;
    if (fit == null || !fit.fits || source == null) return;
    setState(() {
      _packing = true;
      _error = null;
    });
    final String? link;
    try {
      link = await source.pack(fit.kept(_picked));
    } catch (e) {
      logFailure("share", "packing a chat failed", e);
      if (mounted) {
        setState(() => _packing = false);
        say(context, "Could not share this chat: $e");
      }
      return;
    }
    if (!mounted) return;
    if (link == null) {
      // The measure said it fits; a file that grew since says otherwise.
      setState(() {
        _packing = false;
        _error = "The files changed while picking them. Try again.";
      });
      return;
    }
    Navigator.of(context).pop(link);
  }

  void _move(int by) {
    final count = _entries.$2.length;
    if (count == 0) return;
    setState(() => _active = (_active + by).clamp(0, count - 1));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    final (items, lines) = _entries;
    final active = lines.isEmpty ? 0 : _active.clamp(0, lines.length - 1);
    final activeLine = lines.elementAtOrNull(active);
    final fit = _fit;
    final dropped = fit?.dropped ?? const <ShareSection>{};
    final ready = fit != null && fit.fits && !_packing;
    final error = theme.colorScheme.error;

    /// What a line looks like left out: everything in it red.
    TextStyle? leftOut(ShareSection section, bool ticked, TextStyle? style) =>
        ticked && dropped.contains(section)
        ? (style ?? const TextStyle()).copyWith(color: error)
        : style;

    Widget fileLine(_Row r, {required bool selected}) {
      final ticked = _isPicked(r);
      return CheckboxListTile(
        dense: true,
        value: ticked,
        onChanged: _packing ? null : (_) => _toggle(r),
        selected: selected,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: r.section == ShareSection.attachments
            ? const EdgeInsets.only(left: 40, right: 16)
            : null,
        title: Text(
          r.label,
          overflow: TextOverflow.ellipsis,
          style: leftOut(r.section, ticked, null),
        ),
        secondary: Text(
          r.file.suggested
              ? formatSize(r.file.size)
              : r.file.folder
              ? "Secret or build folder"
              : "Secret or build file",
          style: leftOut(r.section, ticked, theme.textTheme.bodySmall),
        ),
      );
    }

    Widget allAttachmentsLine({required bool selected}) {
      final all = _rowsIn(ShareSection.attachments);
      final ticked = _attachmentsTicked;
      final size = all.fold(0, (sum, r) => sum + r.file.size);
      return CheckboxListTile(
        dense: true,
        tristate: true,
        value: ticked,
        onChanged: _packing ? null : (_) => _toggleAttachments(),
        selected: selected,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          "Chat Attachments",
          style: leftOut(
            ShareSection.attachments,
            ticked ?? true,
            theme.textTheme.titleSmall,
          ),
        ),
        subtitle: Text(
          "${all.length} ${all.length == 1 ? "file" : "files"}, "
          "${formatSize(size)}",
          style: leftOut(
            ShareSection.attachments,
            ticked ?? true,
            theme.textTheme.bodySmall,
          ),
        ),
        secondary: IconButton(
          tooltip: _attachmentsOpen ? "Hide attachments" : "Show attachments",
          icon: Icon(_attachmentsOpen ? Icons.expand_less : Icons.expand_more),
          onPressed: () => setState(() => _attachmentsOpen = !_attachmentsOpen),
        ),
      );
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge),
    );

    Widget item(_Item item) => switch (item) {
      _Divider() => const Divider(height: 24),
      _Heading(:final text) => heading(text),
      _Row() => fileLine(item, selected: identical(item, activeLine)),
      _AllAttachmentsLine() => allAttachmentsLine(
        selected: identical(item, activeLine),
      ),
    };
    final noMatch =
        (rows?.values.any((r) => r.isNotEmpty) ?? false) && lines.isEmpty;

    final (String status, bool alarming) = switch (fit) {
      _ when _error != null => (_error!, true),
      null => ("Measuring the link…", false),
      ShareFit(fits: false) => (
        "Too long to share as a link, even with no files: "
            "${formatSize(fit.length)} of ${formatSize(appLinkMaxLength)}.",
        true,
      ),
      ShareFit(:final dropped) when dropped.isNotEmpty => (
        "Too long for a link: what is in red is left out. Untick something "
            "to keep the rest.",
        true,
      ),
      _ => (
        "${formatSize(fit.length)} of ${formatSize(appLinkMaxLength)} "
            "of link.",
        false,
      ),
    };

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.space, control: true): () {
          if (activeLine != null) _toggleLine(activeLine);
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
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
                  child: SearchField(
                    controller: _search,
                    hint: "Search files to share",
                    padding: EdgeInsets.zero,
                    autofocus: true,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) {
                      if (ready) _share();
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: items.length + (noMatch ? 2 : 1),
                    itemBuilder: (context, i) => i == 0
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                            child: Text(
                              "The conversation and its sub-agents always go. "
                              "Anyone with the link can read all of it.",
                              style: theme.textTheme.bodySmall,
                            ),
                          )
                        : i <= items.length
                        ? item(items[i - 1])
                        : const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text("No file matches")),
                          ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: alarming ? error : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: ready ? _share : null,
                  icon: _packing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share),
                  label: const Text("Share"),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
