import "package:re_highlight/re_highlight.dart";

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

import "../app/transcript/code.dart";

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
final grammars = <String, Mode>{
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
final highlighter = Highlight()..registerLanguages(grammars);

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
  final mode = key == null ? null : highlighter.getLanguage(key);
  if (mode == null) return null;
  for (final MapEntry(key: name, value: grammar) in grammars.entries) {
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

/// [CodeHighlighter] over the grammars above.
class GrammarHighlighter implements CodeHighlighter {
  const GrammarHighlighter();

  @override
  List<CodeToken> tokens(String code, String? language) {
    final plain = [CodeToken(code)];
    if (language == null || highlighter.getLanguage(language) == null) {
      return plain;
    }
    final result = highlighter.highlight(code: code, language: language);
    // A run that broke off emitted only the code up to the break.
    if (result.errorRaised != null) return plain;
    final renderer = _TokenRenderer();
    result.render(renderer);
    return renderer.tokens;
  }
}

class _TokenRenderer implements HighlightRenderer {
  final tokens = <CodeToken>[];
  final _scopes = <String?>[];

  @override
  void addText(String text) {
    final scope = _scopes.lastWhere((s) => s != null, orElse: () => null);
    final last = tokens.lastOrNull;
    if (last != null && last.scope == scope) {
      tokens[tokens.length - 1] = CodeToken(last.text + text, scope);
    } else {
      tokens.add(CodeToken(text, scope));
    }
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) => _scopes.removeLast();
}
