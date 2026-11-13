import "package:entoli_glass/entoli_glass.dart" as wire;
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/transcript/code.dart";
import "../../app/transcript/formula.dart";
import "../../core/code_grammars.dart" show grammarOfFile;
import "../../core/log.dart";
import "../../providers.dart";
import "markdown_encoder.dart";

/// Markdown the native shell shows outside the conversation, parsed and
/// encoded as a reply's is, and the links tapped in it opened over
/// [_context], the bridge's.
class ShellDocuments implements wire.DocumentIntents {
  ShellDocuments(this._container, this._context);

  final ProviderContainer _container;
  final BuildContext Function() _context;
  final _client = wire.NativeTranscript();

  /// One per ink, each formula sent once.
  final _sheets = <int, FormulaSheet>{};

  @override
  Future<List<wire.TextBlockSnapshot>> markdown(String text, bool dark) async {
    final ink = inkOf(dark: dark);
    final sheet = _sheets[ink] ??= FormulaSheet(
      _container.read(formulaRendererProvider),
      argb: ink,
      // Typeset before encoding, so nothing lands after.
      onReady: () {},
    );
    await sheet.typeset(text);
    final blocks = MarkdownEncoder(
      formulas: sheet,
      highlighter: _container.read(codeHighlighterProvider),
    ).markdown(text);
    final pictures = sheet.take();
    if (pictures.isNotEmpty) {
      await _client.formulas(pictures).catchError((Object e) {
        logFailure("shell", "document formulas", e);
      });
    }
    return blocks;
  }

  @override
  List<wire.CodeTokenSnapshot> highlight(String code, String name) => [
    for (final token
        in _container
            .read(codeHighlighterProvider)
            .tokens(code, grammarOfFile(name)?.name))
      wire.CodeTokenSnapshot(text: token.text, scope: token.scope),
  ];

  @override
  Future<void> link(String href) async {
    final uri = Uri.tryParse(href);
    final context = _context();
    if (uri != null && context.mounted) {
      await _container.read(linkOpenerProvider).open(context, uri);
    }
  }
}
