import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_math_fork/flutter_math.dart";
import "package:flutter_math_fork/tex.dart";
import "package:markdown/markdown.dart" as md;

import "../../../domain/math_syntax.dart";
import "../../fonts.dart";
import "../../selection/selectable_formula.dart";
import "code_block.dart";

typedef _Parsed = ({SyntaxTree? tree, ParseException? error});

/// One `MarkdownText`'s formulas: the builders that draw them, and the parsed
/// trees they draw from, kept for the reason the code blocks' spans are —
/// `MarkdownBody` re-parses whenever its style sheet changes, which is every
/// frame of a palette's cross-fade, and `Math.tex` parses its TeX as it is
/// constructed.
///
/// **A tree is drawn in one place at a time.** `flutter_math_fork` keeps
/// the widget it built on each node, and an equation row's carries a
/// `GlobalKey`, so one tree drawn twice puts one key in two places: layout
/// fails, and the whole chat with it. Trees are therefore this widget's own,
/// not shared with another reply, and one per occurrence of a TeX string —
/// the second `$x$` in a reply is the second tree for `x`. [restart] begins
/// the count again before each build, so a re-parse hands each formula the
/// tree it had, and a re-parse is still not a re-parse of the TeX.
class MathBuilders {
  late final Map<String, MarkdownElementBuilder> builders = {
    mathInlineTag: _MathBuilder(this),
    mathDisplayTag: _MathBuilder(this),
  };

  final _trees = <String, List<_Parsed>>{};
  final _taken = <String, int>{};

  /// Bounded and evicted oldest-first, as the code blocks' cache is.
  static const _limit = 64;

  void restart() => _taken.clear();

  _Parsed _take(String tex) {
    final n = _taken[tex] = (_taken[tex] ?? 0) + 1;
    if (!_trees.containsKey(tex) && _trees.length >= _limit) {
      _trees.remove(_trees.keys.first);
    }
    final trees = _trees.putIfAbsent(tex, () => []);
    while (trees.length < n) {
      trees.add(_parse(tex));
    }
    return trees[n - 1];
  }
}

_Parsed _parse(String tex) {
  try {
    return (
      tree: SyntaxTree(
        greenRoot: TexParser(tex, const TexParserSettings()).parse(),
      ),
      error: null,
    );
  } on ParseException catch (e) {
    return (tree: null, error: e);
  } on Object catch (e) {
    // What `Math.tex` does with a throw that is not the parser's own.
    return (tree: null, error: ParseException("$e"));
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
  _MathBuilder(this._formulas);

  final MathBuilders _formulas;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final style = parentStyle ?? Theme.of(context).textTheme.bodyMedium;
    final parsed = _formulas._take(element.attributes[mathTexAttribute] ?? "");
    // Selected whole, and copied as the TeX it was written as — the
    // element's text is its source, delimiters and all.
    final math = SelectableFormula(
      written: element.textContent,
      child: Math(
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
