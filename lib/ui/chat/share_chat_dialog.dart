import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:share_plus/share_plus.dart";

import "../../app/chat_shares.dart";
import "../../core/formatting.dart" show formatSize;
import "../../core/log.dart";
import "../../data/chat_share.dart" show ShareCandidates, ShareFile;
import "../../domain/chat_share.dart";
import "../../domain/chat_store.dart" show attachmentFilename;
import "../../domain/models.dart";
import "../widgets/dialogs.dart" show copyToClipboard, notify, say;
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
  final pack = await showDialog<SharePack>(
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
  final link = pack?.link;
  if (link == null || !context.mounted) return;
  await _shareLink(context, link, origin: origin);
  if (!context.mounted) return;
  final dropped = [
    if (pack!.droppedWorkspace) "the workspace files",
    if (pack.droppedArtifacts) "the artifacts",
    if (pack.droppedAttachments) "the attachments",
  ];
  if (dropped.isNotEmpty) {
    notify(context, "The link left out ${dropped.join(" and ")} to fit.");
  }
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

class ShareChatDialog extends ConsumerStatefulWidget {
  const ShareChatDialog({super.key, required this.chat, this.compact = false});

  final ChatState chat;
  final bool compact;

  @override
  ConsumerState<ShareChatDialog> createState() => _ShareChatDialogState();
}

/// The dialog's sections, in the order they are listed.
enum _Section { attachments, artifacts, workspace }

class _Row {
  const _Row(this.file, {required this.section, required this.label});

  final ShareFile file;
  final _Section section;
  final String label;
}

class _ShareChatDialogState extends ConsumerState<ShareChatDialog> {
  final _search = TextEditingController();
  List<_Row>? _rows;
  final _picked = {for (final section in _Section.values) section: <String>{}};
  int _active = 0;
  bool _packing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() => _active = 0));
    _load();
  }

  Future<void> _load() async {
    final shares = ref.read(chatSharesProvider);
    final ShareCandidates candidates;
    final Map<String, String> titles;
    try {
      candidates = await shares.candidates(widget.chat);
      titles = await shares.artifactTitles(widget.chat);
    } catch (e) {
      logFailure("share", "listing a chat's files failed", e);
      if (mounted) setState(() => _rows = const []);
      return;
    }
    if (!mounted) return;
    setState(() {
      _rows = [
        for (final file in candidates.attachments)
          _Row(
            file,
            section: _Section.attachments,
            label: attachmentFilename(file.path),
          ),
        for (final file in candidates.artifacts)
          _Row(
            file,
            section: _Section.artifacts,
            label: titles[file.path] ?? file.path,
          ),
        for (final file in candidates.workspace)
          _Row(file, section: _Section.workspace, label: file.path),
      ];
      for (final row in _rows!) {
        if (row.file.suggested) _setOf(row).add(row.file.path);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Set<String> _setOf(_Row row) => _picked[row.section]!;

  void _toggle(_Row row) => setState(() {
    final set = _setOf(row);
    set.contains(row.file.path)
        ? set.remove(row.file.path)
        : set.add(row.file.path);
  });

  List<_Row> get _shown {
    final query = _search.text.trim().toLowerCase();
    final rows = _rows ?? const [];
    return query.isEmpty
        ? rows
        : rows.where((r) => r.label.toLowerCase().contains(query)).toList();
  }

  Future<void> _share() async {
    setState(() {
      _packing = true;
      _error = null;
    });
    final SharePack pack;
    try {
      pack = await ref
          .read(chatSharesProvider)
          .pack(
            widget.chat,
            attachments: _picked[_Section.attachments]!,
            workspace: _picked[_Section.workspace]!,
            artifacts: _picked[_Section.artifacts]!,
          );
    } catch (e) {
      logFailure("share", "packing a chat failed", e);
      if (mounted) {
        setState(() => _packing = false);
        say(context, "Could not share this chat: $e");
      }
      return;
    }
    if (!mounted) return;
    if (pack.link == null) {
      setState(() {
        _packing = false;
        _error =
            "Too long to share as a link, even with no files: "
            "${formatSize(pack.length ?? 0)} of "
            "${formatSize(shareLinkMaxLength)}.";
      });
      return;
    }
    Navigator.of(context).pop(pack);
  }

  void _move(int by) {
    final count = _shown.length;
    if (count == 0) return;
    setState(() => _active = (_active + by).clamp(0, count - 1));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final active = shown.isEmpty ? 0 : _active.clamp(0, shown.length - 1);
    final theme = Theme.of(context);
    final rows = _rows;
    List<_Row> rowsIn(_Section section) =>
        shown.where((r) => r.section == section).toList();
    final attachments = rowsIn(_Section.attachments);
    final artifacts = rowsIn(_Section.artifacts);
    final workspace = rowsIn(_Section.workspace);
    final picked = [
      for (final row in rows ?? const <_Row>[])
        if (_setOf(row).contains(row.file.path)) row.file.size,
    ].fold(0, (a, b) => a + b);
    Widget row(_Row r) {
      final index = shown.indexOf(r);
      return CheckboxListTile(
        dense: true,
        value: _setOf(r).contains(r.file.path),
        onChanged: _packing ? null : (_) => _toggle(r),
        selected: index == active,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(r.label, overflow: TextOverflow.ellipsis),
        secondary: Text(
          r.file.suggested ? formatSize(r.file.size) : "Secret or build file",
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.space, control: true): () {
          if (shown.isNotEmpty) _toggle(shown[active]);
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
                      if (!_packing) _share();
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
                      if (attachments.isNotEmpty) ...[
                        heading("Chat Attachments"),
                        ...attachments.map(row),
                        if (artifacts.isNotEmpty || workspace.isNotEmpty)
                          const Divider(height: 24),
                      ],
                      if (artifacts.isNotEmpty) ...[
                        heading("Artifacts"),
                        ...artifacts.map(row),
                      ],
                      if (workspace.isNotEmpty) ...[
                        heading("Workspace"),
                        ...workspace.map(row),
                      ],
                      if (rows.isNotEmpty && shown.isEmpty)
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
                    _error ??
                        "${formatSize(picked)} of files picked. Past "
                            "${formatSize(shareLinkMaxLength)} of link, the "
                            "workspace goes, then the artifacts, then the "
                            "attachments.",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _error == null ? null : theme.colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _packing || rows == null ? null : _share,
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
