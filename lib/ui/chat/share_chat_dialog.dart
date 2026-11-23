import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:share_plus/share_plus.dart";

import "../../app/chat_shares.dart";
import "../../core/formatting.dart" show formatSize;
import "../../core/log.dart";
import "../../data/chat_share.dart" show ChatShareSource, ShareFile;
import "../../domain/chat_share.dart";
import "../../domain/chat_store.dart" show attachmentFilename;
import "../../domain/models.dart";
import "../widgets/dialogs.dart" show copyToClipboard, say;
import "../widgets/nav_drawer.dart" show compactWidth;
import "../widgets/search_field.dart";

/// Share on a chat: which of its files go with it, then the system's share
/// sheet with the link. Framed as the project palette is — the whole screen on
/// a phone, a box in the middle of anything wider.
Future<void> showShareChat(
  BuildContext context,
  ChatState chat, {
  Rect? origin,
}) async {
  final compact = MediaQuery.sizeOf(context).width < compactWidth;
  final link = await showDialog<String>(
    context: context,
    builder: (_) => compact
        ? Dialog.fullscreen(child: ShareChatDialog(chat: chat, compact: true))
        : Dialog(
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
              child: ShareChatDialog(chat: chat),
            ),
          ),
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

class _Row {
  const _Row(this.file, {required this.section, required this.label});

  final ShareFile file;
  final ShareSection section;
  final String label;
}

/// One line of the list, the one the arrow keys move between: a file, or
/// the line ticking every chat attachment at once.
sealed class _Line {
  const _Line();
}

final class _FileLine extends _Line {
  const _FileLine(this.row);

  final _Row row;
}

final class _AllAttachmentsLine extends _Line {
  const _AllAttachmentsLine();
}

class _ShareChatDialogState extends ConsumerState<ShareChatDialog> {
  final _search = TextEditingController();
  ChatShareSource? _source;
  List<_Row>? _rows;
  final SharePicks _picked = {
    for (final section in ShareSection.values) section: <String>{},
  };

  /// What the zip costs bare, and what each ticked piece adds: measured
  /// once each, in the order they were ticked.
  int? _base;
  final Map<(ShareSection, String), int> _costs = {};
  final List<(ShareSection, String)> _toMeasure = [];
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
    final List<_Row> rows;
    try {
      source = await shares.source(widget.chat);
      final candidates = await source.candidates();
      final titles = await shares.artifactTitles(widget.chat);
      rows = [
        for (final file in candidates.attachments)
          _Row(
            file,
            section: ShareSection.attachments,
            label: attachmentFilename(file.path),
          ),
        for (final file in candidates.artifacts)
          _Row(
            file,
            section: ShareSection.artifacts,
            label: titles[file.path] ?? file.path,
          ),
        for (final file in candidates.workspace)
          _Row(file, section: ShareSection.workspace, label: file.path),
      ];
    } catch (e) {
      logFailure("share", "listing a chat's files failed", e);
      if (mounted) setState(() => _rows = const []);
      return;
    }
    if (!mounted) return;
    setState(() {
      _source = source;
      _rows = rows;
      for (final row in rows) {
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

  /// Ticks [row], measuring it the first time it is ticked.
  void _pick(_Row row) {
    _picked[row.section]!.add(row.file.path);
    final key = (row.section, row.file.path);
    if (!_costs.containsKey(key) && !_toMeasure.contains(key)) {
      _toMeasure.add(key);
      _measureNext();
    }
  }

  Future<void> _measureNext() async {
    final source = _source;
    if (_measuring || _toMeasure.isEmpty || source == null) return;
    _measuring = true;
    final (section, id) = _toMeasure.first;
    try {
      final cost = await source.cost(section, id);
      if (!mounted) return;
      setState(() => _costs[(section, id)] = cost);
    } catch (e) {
      logFailure("share", "measuring a shared file failed", e);
      // Unmeasurable is unpackable: untick it rather than wait on it.
      if (mounted) setState(() => _picked[section]!.remove(id));
    } finally {
      _toMeasure.remove((section, id));
      _measuring = false;
    }
    _measureNext();
  }

  void _toggle(_Row row) => setState(() {
    _isPicked(row) ? _picked[row.section]!.remove(row.file.path) : _pick(row);
  });

  List<_Row> _rowsIn(ShareSection section) =>
      (_rows ?? const []).where((r) => r.section == section).toList();

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

  /// The lines on screen, in order. A search opens the attachments to show
  /// which of them match.
  List<_Line> get _lines {
    final attachments = _matching(ShareSection.attachments);
    return [
      if (attachments.isNotEmpty) const _AllAttachmentsLine(),
      if (_attachmentsOpen || _query.isNotEmpty)
        for (final row in attachments) _FileLine(row),
      for (final row in _matching(ShareSection.artifacts)) _FileLine(row),
      for (final row in _matching(ShareSection.workspace)) _FileLine(row),
    ];
  }

  void _toggleLine(_Line line) => switch (line) {
    _FileLine(:final row) => _toggle(row),
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
    final count = _lines.length;
    if (count == 0) return;
    setState(() => _active = (_active + by).clamp(0, count - 1));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    final lines = _lines;
    final active = lines.isEmpty ? 0 : _active.clamp(0, lines.length - 1);
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
          r.file.suggested ? formatSize(r.file.size) : "Secret or build file",
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

    Widget line(int index) {
      final selected = index == active;
      return switch (lines[index]) {
        _FileLine(:final row) => fileLine(row, selected: selected),
        _AllAttachmentsLine() => allAttachmentsLine(selected: selected),
      };
    }

    final firstArtifact = lines.indexWhere(
      (l) => l is _FileLine && l.row.section == ShareSection.artifacts,
    );
    final firstWorkspace = lines.indexWhere(
      (l) => l is _FileLine && l.row.section == ShareSection.workspace,
    );
    final hasAttachments = lines.firstOrNull is _AllAttachmentsLine;
    final firstFile = [firstArtifact, firstWorkspace]
        .where((i) => i >= 0)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);

    final (String status, bool alarming) = switch (fit) {
      _ when _error != null => (_error!, true),
      null => ("Measuring the link…", false),
      ShareFit(fits: false) => (
        "Too long to share as a link, even with no files: "
            "${formatSize(fit.length)} of ${formatSize(shareLinkMaxLength)}.",
        true,
      ),
      ShareFit(:final dropped) when dropped.isNotEmpty => (
        "Too long for a link: what is in red is left out. Untick something "
            "to keep the rest.",
        true,
      ),
      _ => (
        "${formatSize(fit.length)} of ${formatSize(shareLinkMaxLength)} "
            "of link.",
        false,
      ),
    };

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.space, control: true): () {
          if (lines.isNotEmpty) _toggleLine(lines[active]);
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
                : ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          "The conversation and its sub-agents always go. "
                          "Anyone with the link can read all of it.",
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      for (var i = 0; i < lines.length; i++) ...[
                        if (hasAttachments && i == firstFile)
                          const Divider(height: 24),
                        if (i == firstArtifact) heading("Artifacts"),
                        if (i == firstWorkspace) heading("Workspace"),
                        line(i),
                      ],
                      if (rows.isNotEmpty && lines.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text("No file matches")),
                        ),
                    ],
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
