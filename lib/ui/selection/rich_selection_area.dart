import "dart:async";

import "package:flutter/foundation.dart" show defaultTargetPlatform;
import "package:flutter/material.dart";
import "package:flutter/rendering.dart";

import "../../core/platform/rich_clipboard.dart";
import "copied_document.dart";
import "copy_format.dart";
import "selection_reader.dart";

/// A selection over rendered markdown that copies as both of what it is: the
/// formatted text for a target that keeps formatting, and the markdown for
/// one that takes plain text. Everything a copy of a selection is — the
/// container the fragments register with, Ctrl+C, the menu's Copy, the
/// clipboard — is in here, so whatever is wrapped in it only says what
/// [markdown] it drew.
///
/// One area and one container for all of [child], so a drag runs from the
/// first paragraph to the last; anything inside that is chrome rather than
/// what was said wraps itself in `SelectionContainer.disabled`.
class RichSelectionArea extends StatefulWidget {
  const RichSelectionArea({
    super.key,
    required this.markdown,
    this.clipboard = richClipboard,
    required this.child,
  });

  /// What [child] rendered, read when a copy asks which kind of block each
  /// paragraph was.
  final String markdown;

  final RichClipboard clipboard;
  final Widget child;

  @override
  State<RichSelectionArea> createState() => _RichSelectionAreaState();
}

class _RichSelectionAreaState extends State<RichSelectionArea> {
  /// Held across rebuilds: a streamed reply rebuilds every frame, and a
  /// delegate per build would drop the selection under the drag making it.
  late final _selection = RichSelectionDelegate(
    markdown: () => widget.markdown,
    root: () => mounted ? context.findRenderObject() : null,
  );

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  /// Read before anything is awaited: the menu clears the selection as soon
  /// as its item returns.
  Future<void> _copy() async {
    final content = await _selection.clipboardContent();
    if (content != null) await widget.clipboard.write(content);
  }

  /// The framework's menu with its Copy swapped for [_copy]; what follows a
  /// copy is what the framework's own does.
  Widget _menu(BuildContext context, SelectableRegionState region) =>
      AdaptiveTextSelectionToolbar.buttonItems(
        anchors: region.contextMenuAnchors,
        buttonItems: [
          for (final item in region.contextMenuButtonItems)
            if (item.type == ContextMenuButtonType.copy)
              item.copyWith(
                onPressed: () {
                  unawaited(_copy());
                  switch (defaultTargetPlatform) {
                    case TargetPlatform.android || TargetPlatform.fuchsia:
                      region.clearSelection();
                    case TargetPlatform.iOS:
                      region.hideToolbar(false);
                    case TargetPlatform.linux ||
                        TargetPlatform.macOS ||
                        TargetPlatform.windows:
                      region.hideToolbar();
                  }
                },
              )
            else
              item,
        ],
      );

  // The region's own copy writes plain text, so Ctrl+C is taken over here —
  // its copy action defers to one above it — and the menu's in [_menu].
  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
        onInvoke: (_) => unawaited(_copy()),
      ),
    },
    child: SelectionArea(
      contextMenuBuilder: _menu,
      child: SelectionContainer(delegate: _selection, child: widget.child),
    ),
  );
}

/// The one container between the area and every fragment — heading,
/// paragraph, list item, code line, formula — so the drag, the handles and
/// the edges are the framework's own, and a copy reads the same fragments the
/// highlight is drawn on.
///
/// [getSelectedContent] is what the framework itself reads, and answers the
/// markdown; [clipboardContent] is both halves of a copy.
class RichSelectionDelegate extends StaticSelectionContainerDelegate {
  RichSelectionDelegate({required this.markdown, required this.root});

  final String Function() markdown;
  final RenderObject? Function() root;

  /// What is selected, read into a document; null where nothing is — a
  /// selection collapsed to a point copies nothing, since an empty clipboard
  /// is a copy reporting success over nothing.
  CopiedDocument? selectedDocument() {
    final fragments = _fragments();
    if (fragments.isEmpty) return null;
    final document = SelectionReader(
      root: root(),
      markdown: markdown(),
    ).read(fragments);
    return document.isEmpty ? null : document;
  }

  /// Both halves of a copy. The selection is read on the first line, before
  /// anything is awaited; only drawing its formulas waits.
  Future<ClipboardContent?> clipboardContent() async {
    final document = selectedDocument();
    return document == null ? null : clipboardContentOf(document);
  }

  @override
  SelectedContent? getSelectedContent() {
    final document = selectedDocument();
    return document == null
        ? null
        : SelectedContent(
            plainText: const MarkdownCopyFormat().write(document),
          );
  }

  /// Each selectable with something selected, in order, and whether it shares
  /// a rendered line with what went before: one that does not overlap the
  /// lines selected so far vertically starts a block of its own.
  List<SelectedFragment> _fragments() {
    final found = <SelectedFragment>[];
    Rect? covered;
    for (final Selectable selectable in selectables) {
      final selected = selectable.getSelectedContent();
      if (selected == null || selected.plainText.isEmpty) continue;
      final line = MatrixUtils.transformRect(
        selectable.getTransformTo(null),
        selectable.boundingBoxes.first,
      );
      final sameLine =
          covered != null &&
          line.top <= covered.bottom &&
          line.bottom >= covered.top;
      found.add((
        selectable: selectable,
        selected: selected.plainText,
        sameLine: sameLine,
      ));
      covered = covered?.expandToInclude(line) ?? line;
    }
    return found;
  }
}
