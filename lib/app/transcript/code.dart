import "package:flutter_riverpod/flutter_riverpod.dart";

/// A run of code and the grammar's name for what it is — `keyword`,
/// `string`, `title.function_`, highlight.js's scopes — or null for plain
/// text. A frontend colours each scope its own way.
class CodeToken {
  const CodeToken(this.text, [this.scope]);

  final String text;
  final String? scope;
}

/// Splits code into [CodeToken]s by the grammar a fence named. The grammars
/// are drawing-free data, but the library carrying them is not, so the
/// highlighter is bound at the root like the formula renderer.
abstract interface class CodeHighlighter {
  /// [code] as tokens, or one plain token where [language] names no grammar
  /// this build has or the run broke off.
  List<CodeToken> tokens(String code, String? language);
}

final codeHighlighterProvider = Provider<CodeHighlighter>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);
