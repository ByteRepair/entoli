import "package:flutter/rendering.dart";
import "package:flutter/widgets.dart";

/// Says a block drawn by the app's own widget is code, for the selection to
/// read back. Markdown's own blocks — headings, list items, cells — are read
/// from the reply's markdown; a block the app draws itself says so here, and
/// says what the markdown cannot tie to it: which language it was fenced as.
class CopiedBlockScope extends SingleChildRenderObjectWidget {
  const CopiedBlockScope.code({super.key, this.language, required super.child});

  final String? language;

  @override
  RenderCopiedBlockScope createRenderObject(BuildContext context) =>
      RenderCopiedBlockScope(language);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCopiedBlockScope renderObject,
  ) => renderObject.language = language;
}

class RenderCopiedBlockScope extends RenderProxyBox {
  RenderCopiedBlockScope(this.language);

  String? language;
}
