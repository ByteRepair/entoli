import "package:flutter/material.dart";
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

import "../../fonts.dart";
import "../../selection/copied_block_scope.dart";
import "../../widgets/action_icon.dart";
import "../../widgets/dialogs.dart";

/// The grammars a fence can name. `re_highlight` ships 197, and registering
/// all of them costs 359 KB gzipped where these thirty-one cost 56 KB — a
/// grammar is data, so nothing tree-shakes the ones nobody names and every
/// install pays for them. This is what a coding agent on
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

/// The grammar a workspace file is highlighted with, from its name: the
/// extension as a grammar's own name or one of its aliases, which is how a
/// fence names one too. A few names carry no extension, and a few extensions
/// are a dialect no grammar lists.
({String name, Mode mode})? grammarOfFile(String fileName) {
  final base = fileName.split("/").last.toLowerCase();
  final dot = base.lastIndexOf(".");
  final key =
      _grammarByName[base] ??
      (dot > 0
          ? _grammarByExtension[base.substring(dot + 1)] ??
                base.substring(dot + 1)
          : null);
  final mode = key == null ? null : _highlight.getLanguage(key);
  if (mode == null) return null;
  for (final MapEntry(key: name, value: grammar) in _grammars.entries) {
    if (identical(grammar, mode)) return (name: name, mode: mode);
  }
  return null;
}

const _grammarByName = {
  "makefile": "makefile",
  "gnumakefile": "makefile",
  "dockerfile": "dockerfile",
  "containerfile": "dockerfile",
  "cmakelists.txt": "cmake",
  ".bashrc": "bash",
  ".zshrc": "bash",
  ".profile": "bash",
  ".env": "properties",
};

const _grammarByExtension = {
  "jsonl": "json",
  "cfg": "ini",
  "conf": "ini",
  "env": "properties",
  "htm": "xml",
};

/// What `MarkdownBody` is given. One for the app rather than one per message:
/// the builder holds nothing and is read only while markdown is parsed, and
/// sharing it is also what lets the highlighted spans below be shared.
final codeBlockBuilders = <String, MarkdownElementBuilder>{
  "pre": CodeBlockBuilder(),
};

/// Highlighted spans, kept because the same block is highlighted again far
/// more often than it changes. `MarkdownBody` re-parses whenever its style
/// sheet does, so switching palette re-runs every grammar on screen once per
/// frame of the theme's cross-fade, and scrolling a block out of the list and
/// back rebuilds it from scratch.
///
/// Bounded by count and evicted oldest-first, since what it holds is the text
/// of every block in it: a cache that grew with the conversation would be a
/// second copy of the chat, in a process that already holds one.
final _spans =
    <
      ({String code, String? language, TextStyle style, Brightness brightness}),
      TextSpan
    >{};
const _spanCacheLimit = 16;

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
      span: cachedSpanOf(code, language, theme),
    );
  }

  /// Keyed on everything the span is a function of, [style] included rather
  /// than only the brightness that picks it: a `TextStyle` is value-equal, so
  /// naming it is what stops a palette that changed anything else from being
  /// answered out of the cache.
  static TextSpan cachedSpanOf(String code, String? language, ThemeData theme) {
    final style = codeBlockStyle(theme);
    final key = (
      code: code,
      language: language,
      style: style,
      brightness: theme.brightness,
    );
    final cached = _spans[key];
    if (cached != null) return cached;

    if (_spans.length >= _spanCacheLimit) _spans.remove(_spans.keys.first);
    return _spans[key] = _spanOf(code, language, style, theme.brightness);
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
  /// `result.illegal` is not the second of those: it is only ever set behind
  /// `ignoreIllegals`, which is on.
  static TextSpan _spanOf(
    String code,
    String? language,
    TextStyle style,
    Brightness brightness,
  ) {
    final plain = TextSpan(text: code, style: style);
    if (language == null || _highlight.getLanguage(language) == null) {
      return plain;
    }

    final result = _highlight.highlight(code: code, language: language);
    if (result.errorRaised != null) return plain;

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

/// What both code styles below are built on, so the two can only differ in
/// what each of them adds. See `monoFamily` for why the face is bundled.
TextStyle _codeFont(ThemeData theme) => TextStyle(
  fontFamily: monoFamily,
  // Mono faces run wider than the prose beside them, so matching the body
  // size makes inline code look larger than the sentence holding it.
  fontSize: theme.textTheme.bodyMedium!.fontSize! * 0.85,
  color: theme.colorScheme.onSurface,
);

/// What inline `code` adds: a surface, so a word in a sentence reads as code
/// rather than as the same sentence in another face. `fromTheme` asks for
/// `cardTheme.color`, which M3 leaves null, so until now it added nothing.
///
/// A `backgroundColor` paints tight to the glyphs with no room either side.
/// The alternative is a builder for `code` returning a padded `WidgetSpan`,
/// which is what a block gets — but a block is one thing on a line of its own,
/// while inline code has to wrap with the sentence, and a `WidgetSpan` cannot
/// break across lines.
///
/// **Translucent, not a surface colour.** A paragraph paints its selection
/// highlight first and its text after, span backgrounds included, so an
/// opaque background hid the highlight wherever it fell on inline code.
/// [_inlineCodeTint] of the text colour over the page reads as the same
/// raised surface and lets the highlight show through.
TextStyle inlineCodeStyle(ThemeData theme) => _codeFont(theme).copyWith(
  backgroundColor: theme.colorScheme.onSurface.withValues(
    alpha: _inlineCodeTint,
  ),
);

/// How much of the text colour inline code's background carries.
const _inlineCodeTint = 0.08;

/// What a block adds: room between the lines, because a block is read as lines
/// where an inline span is read as part of a sentence. Public because the
/// composer sets its field in it while a `!` command is being typed, so what is
/// about to run looks like what it is.
TextStyle codeBlockStyle(ThemeData theme) =>
    _codeFont(theme).copyWith(height: 1.45);

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
    this.span,
  });

  final String code;
  final String? language;

  /// Omit where there is nothing to highlight — a command's output is not a
  /// language — and the cache answers with the plain span. Handed in by the
  /// markdown builder, which has it in hand from the parse.
  final TextSpan? span;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      // The bar is the block's chrome rather than anything the model said,
      // so a drag across the reply must not put the language name on the
      // clipboard — the rule the labels above the bubble already keep.
      SelectionContainer.disabled(child: _bar(context)),
      SidewaysScroll(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        // Says it is code, and which, to a selection copying it: what was
        // fenced is not in the words.
        child: CopiedBlockScope.code(
          language: language,
          child: Text.rich(
            span ??
                CodeBlockBuilder.cachedSpanOf(
                  code,
                  language,
                  Theme.of(context),
                ),
          ),
        ),
      ),
    ],
  );

  Widget _bar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 12, right: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: Text(
              language ?? "",
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // The snack bar copying a message already shows, rather than an icon
          // that turns into a tick: one answer to the one event, and no timer
          // for this to own.
          ActionIcon(
            icon: Icons.copy_outlined,
            tooltip: "Copy code",
            onPressed: () =>
                copyToClipboard(context, code, said: "Code copied"),
          ),
        ],
      ),
    );
  }
}

/// A long line scrolls rather than wrapping, since a wrapped one is no longer
/// the code that was written — nor the formula, which is the other thing set
/// in it. Stateful for the controller alone: a `Scrollbar` and the view it
/// reports on have to be given the same one.
///
/// **What it holds is selected as part of the page around it.** A scroll view
/// is a selection container of its own, which made a code block a block apart
/// to whatever selection crossed it: its highlight and handles were the
/// scroll's to draw, and what it copied was the scroll's text alone. The
/// registrar above is handed straight through, so the lines inside register
/// with the same container as the paragraphs either side of them.
class SidewaysScroll extends StatefulWidget {
  const SidewaysScroll({
    super.key,
    this.padding = EdgeInsets.zero,
    required this.child,
  });

  final EdgeInsets padding;
  final Widget child;

  @override
  State<SidewaysScroll> createState() => _SidewaysScrollState();
}

class _SidewaysScrollState extends State<SidewaysScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: registrar == null
            ? widget.child
            : SelectionRegistrarScope(
                registrar: registrar,
                child: widget.child,
              ),
      ),
    );
  }
}
