import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";

import "copied_document.dart";

/// Says what a block drawn by the app's own widget is, for the selection to
/// read back. Markdown's own blocks — headings, list items, cells — are read
/// from the reply's markdown; a block the app draws itself says so here, and
/// says what the markdown cannot tie to it: which language a code block was
/// fenced as.
class CopiedBlockScope extends SingleChildRenderObjectWidget {
  const CopiedBlockScope.code({super.key, this.language, required super.child})
    : kind = BlockKind.code;

  final BlockKind kind;
  final String? language;

  @override
  RenderCopiedBlockScope createRenderObject(BuildContext context) =>
      RenderCopiedBlockScope(kind, language);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCopiedBlockScope renderObject,
  ) => renderObject
    ..kind = kind
    ..language = language;
}

class RenderCopiedBlockScope extends RenderProxyBox {
  RenderCopiedBlockScope(this.kind, this.language);

  BlockKind kind;
  String? language;

  /// The scope [object] is drawn in, looking no further up than [root].
  static RenderCopiedBlockScope? of(RenderObject object, RenderObject? root) {
    for (RenderObject? node = object.parent; node != null; node = node.parent) {
      if (node is RenderCopiedBlockScope) return node;
      if (identical(node, root)) return null;
    }
    return null;
  }
}
