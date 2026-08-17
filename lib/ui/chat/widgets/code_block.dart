import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:markdown/markdown.dart" as md;
import "package:re_highlight/re_highlight.dart";
import "package:re_highlight/styles/github-dark.dart";
import "package:re_highlight/styles/github.dart";

import "package:re_highlight/languages/bash.dart";
import "package:re_highlight/languages/c.dart";
import "package:re_highlight/languages/cmake.dart";
import "package:re_highlight/languages/cpp.dart";
import "package:re_highlight/languages/csharp.dart";
import "package:re_highlight/languages/css.dart";
import "package:re_highlight/languages/dart.dart";
import "package:re_highlight/languages/diff.dart";
import "package:re_highlight/languages/dockerfile.dart";
import "package:re_highlight/languages/go.dart";
import "package:re_highlight/languages/gradle.dart";
import "package:re_highlight/languages/ini.dart";
import "package:re_highlight/languages/java.dart";
import "package:re_highlight/languages/javascript.dart";
import "package:re_highlight/languages/json.dart";
import "package:re_highlight/languages/kotlin.dart";
import "package:re_highlight/languages/lua.dart";
import "package:re_highlight/languages/makefile.dart";
import "package:re_highlight/languages/markdown.dart";
import "package:re_highlight/languages/php.dart";
import "package:re_highlight/languages/plaintext.dart";
import "package:re_highlight/languages/powershell.dart";
import "package:re_highlight/languages/properties.dart";
import "package:re_highlight/languages/python.dart";
import "package:re_highlight/languages/ruby.dart";
import "package:re_highlight/languages/rust.dart";
import "package:re_highlight/languages/shell.dart";
import "package:re_highlight/languages/sql.dart";
import "package:re_highlight/languages/typescript.dart";
import "package:re_highlight/languages/xml.dart";
import "package:re_highlight/languages/yaml.dart";

/// The grammars a fence can name. `re_highlight` ships 197, and registering
/// all of them costs 359 KB gzipped in the web bundle where these thirty-one
/// cost 56 KB — a grammar is data, so nothing tree-shakes the ones nobody
/// names and every page load pays for them. This is what a coding agent on
/// these three platforms actually emits; Swift is the one deliberate
/// omission, its grammar being larger than all of these put together.
///
/// A fence naming anything else is drawn plain, which is what every fence did
/// before there was any of this, so leaving one out costs nothing worse than
/// the behaviour it replaces. Each grammar brings its own aliases, so `sh`,
/// `html`, `toml` and the rest arrive without being named here.
final _grammars = <String, Mode>{
  "bash": langBash,
  "c": langC,
  "cmake": langCmake,
  "cpp": langCpp,
  "csharp": langCsharp,
  "css": langCss,
  "dart": langDart,
  "diff": langDiff,
  "dockerfile": langDockerfile,
  "go": langGo,
  "gradle": langGradle,
  "ini": langIni,
  "java": langJava,
  "javascript": langJavascript,
  "json": langJson,
  "kotlin": langKotlin,
  "lua": langLua,
  "makefile": langMakefile,
  "markdown": langMarkdown,
  "php": langPhp,
  "plaintext": langPlaintext,
  "powershell": langPowershell,
  "properties": langProperties,
  "python": langPython,
  "ruby": langRuby,
  "rust": langRust,
  "shell": langShell,
  "sql": langSql,
  "typescript": langTypescript,
  "xml": langXml,
  "yaml": langYaml,
};

/// Lazy, like every top-level `final`: a conversation with no fenced block in
/// it never compiles a grammar.
final _highlight = Highlight()..registerLanguages(_grammars);

/// Draws a fenced code block: what it was fenced as, a button that copies it,
/// and the code highlighted underneath.
///
/// A builder rather than `MarkdownBody.syntaxHighlighter`, which is handed the
/// code and nothing else — the language is an attribute of the `code` element
/// inside the `pre`, and the copy button needs somewhere of its own to sit.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final theme = Theme.of(context);
    final language = _languageOf(element);
    // The parser keeps the newline that closed the fence, which would draw as
    // an empty last line.
    final code = element.textContent.replaceFirst(RegExp(r"\n$"), "");
    return CodeBlock(
      code: code,
      language: language,
      span: _spanOf(code, language, _codeTextStyle(theme), theme.brightness),
    );
  }

  /// The fence's info string, which the parser writes onto the `code` element
  /// as `language-<name>`. An indented block was never fenced and has none.
  static String? _languageOf(md.Element pre) {
    for (final child in pre.children ?? const <md.Node>[]) {
      if (child is! md.Element) continue;
      final css = child.attributes["class"];
      if (css != null && css.startsWith("language-")) {
        return css.substring("language-".length);
      }
    }
    return null;
  }

  /// The code as one span. Plain for a language nothing here knows — the
  /// highlighter throws on a name it was not given — and plain again for a run
  /// that broke off, where what was emitted is only the code up to the break
  /// and showing part of a command is worse than showing all of it uncoloured.
  static TextSpan _spanOf(
    String code,
    String? language,
    TextStyle style,
    Brightness brightness,
  ) {
    final plain = TextSpan(text: code, style: style);
    if (language == null || _highlight.getLanguage(language) == null) return plain;

    final result = _highlight.highlight(code: code, language: language);
    if (result.illegal || result.errorRaised != null) return plain;

    // github and github-dark for their token colours. Their `root` entry, the
    // one thing in a highlight theme that is not a token colour, is ignored by
    // the renderer and would be wrong here anyway: the surface below comes
    // from the app's own scheme, so a block belongs to the page it is on
    // rather than to highlight.js.
    final renderer = TextSpanRenderer(
      style,
      brightness == Brightness.dark ? githubDarkTheme : githubTheme,
    );
    result.render(renderer);
    return renderer.span ?? plain;
  }
}

/// What a block is set in. Inline `code` is the style sheet's own and stays
/// that way: it wants a background rather than a size, which is a different
/// change to a different thing.
TextStyle _codeTextStyle(ThemeData theme) => TextStyle(
      fontFamily: "monospace",
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * 0.9,
      height: 1.45,
      color: theme.colorScheme.onSurface,
    );

/// The surface a code block sits on, above the page behind it. It belongs to
/// the markdown style sheet rather than to the block: `pre` is wrapped in the
/// sheet's `codeblockDecoration` whether or not a builder drew what is inside.
BoxDecoration codeBlockDecoration(ThemeData theme) => BoxDecoration(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    );

/// One fenced block, already highlighted: [CodeBlockBuilder] does that while
/// the markdown is parsed, so a scroll frame redraws the block without running
/// a grammar over it again.
class CodeBlock extends StatelessWidget {
  const CodeBlock({
    super.key,
    required this.code,
    required this.language,
    required this.span,
  });

  final String code;
  final String? language;
  final TextSpan span;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The bar is the block's chrome rather than anything the model said,
        // so a drag across the reply must not put the language name on the
        // clipboard — the rule the labels above the bubble already keep.
        SelectionContainer.disabled(child: _bar(theme)),
        _CodeScroll(child: Text.rich(span)),
      ],
    );
  }

  Widget _bar(ThemeData theme) => Container(
        height: 32,
        padding: const EdgeInsets.only(left: 12, right: 4),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Expanded(
              child: Text(
                language ?? "",
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            _CopyButton(code: code),
          ],
        ),
      );
}

/// A long line scrolls rather than wrapping, since a wrapped one is no longer
/// the code that was written. Stateful for the controller alone: a `Scrollbar`
/// and the view it reports on have to be given the same one.
class _CodeScroll extends StatefulWidget {
  const _CodeScroll({required this.child});

  final Widget child;

  @override
  State<_CodeScroll> createState() => _CodeScrollState();
}

class _CodeScrollState extends State<_CodeScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
        controller: _controller,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: widget.child,
        ),
      );
}

/// Copies the block, and reports it the way copying a message already does.
/// An icon that turns into a tick for a second is the other idiom and would be
/// a second answer to the one event, on a timer this widget would then have to
/// own.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.code});

  final String code;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("Code copied")));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      icon: const Icon(Icons.copy_outlined, size: 16),
      tooltip: "Copy code",
      onPressed: () => _copy(context),
      color: theme.colorScheme.onSurfaceVariant,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 28),
    );
  }
}
