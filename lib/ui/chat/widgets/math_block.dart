import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_math_fork/flutter_math.dart";
import "package:flutter_math_fork/tex.dart";
import "package:markdown/markdown.dart" as md;

import "../../../domain/math_syntax.dart";
import "../../fonts.dart";
import "code_block.dart";

final _math = _MathBuilder();

/// A formula for each of the elements `math_syntax.dart` reads out of the
/// text; `MarkdownText` is what hands these to a `MarkdownBody`.
final mathBuilders = <String, MarkdownElementBuilder>{
  mathInlineTag: _math,
  mathDisplayTag: _math,
};

/// Parsed formulas, kept for the reason the code blocks' spans are:
/// `MarkdownBody` re-parses whenever its style sheet changes, which is every
/// frame of a palette's cross-fade, and `Math.tex` parses its TeX as it is
/// constructed. A tree is the TeX's alone — the style is applied as it is
/// drawn — so the key is the source and an entry outlives a theme change.
/// Bounded and evicted oldest-first, as that cache is.
final _trees = <String, ({SyntaxTree? tree, ParseException? error})>{};
const _treeCacheLimit = 64;

({SyntaxTree? tree, ParseException? error}) _parsed(String tex) {
  final cached = _trees[tex];
  if (cached != null) return cached;
  if (_trees.length >= _treeCacheLimit) _trees.remove(_trees.keys.first);
  try {
    return _trees[tex] = (
      tree: SyntaxTree(
        greenRoot: TexParser(tex, const TexParserSettings()).parse(),
      ),
      error: null,
    );
  } on ParseException catch (e) {
    return _trees[tex] = (tree: null, error: e);
  } on Object catch (e) {
    // What `Math.tex` does with a throw that is not the parser's own.
    return _trees[tex] = (tree: null, error: ParseException("$e"));
  }
}

/// Draws a formula with `flutter_math_fork`, KaTeX's layout in pure Dart, so
/// nothing native or web-shaped joins the build.
///
/// An inline formula comes back as a `Text.rich` holding one `WidgetSpan`,
/// which is what lets it sit in the sentence: the builder merges a `Text`'s
/// spans into the paragraph's own, where any other widget would be laid beside
/// the paragraph in a `Wrap` and break the line around it.
class _MathBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final style = parentStyle ?? Theme.of(context).textTheme.bodyMedium;
    final parsed = _parsed(element.attributes[mathTexAttribute] ?? "");
    final math = Math(
      ast: parsed.tree,
      parseError: parsed.error,
      mathStyle: element.tag == mathDisplayTag
          ? MathStyle.display
          : MathStyle.text,
      // The line height is the prose's and not the formula's: a fraction is
      // taller than a line, and carrying the 1.5 into it spaces it out twice.
      textStyle: style?.copyWith(height: 1),
      // TeX the parser will not take is shown as it was written, which still
      // says what the model meant; a blank or an error box says nothing.
      onErrorFallback: (_) => Text(
        element.textContent,
        style: style?.copyWith(fontFamily: monoFamily),
      ),
    );
    if (element.attributes[mathBlockAttribute] != null) {
      // Centred in the column, and scrolled sideways where it is wider than
      // it, since a formula broken across lines is no longer the formula.
      return LayoutBuilder(
        builder: (context, constraints) => SidewaysScroll(
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Center(child: math),
          ),
        ),
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: math,
          ),
        ],
      ),
    );
  }
}
