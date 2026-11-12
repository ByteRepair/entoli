import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_documents.dart";

import "../../harness.dart";
import "fake_native_transcript.dart";

/// Markdown the native shell shows outside a chat: parsed by the core, as a
/// reply is, every block a document can hold drawn.
void main() {
  late FakeNativeTranscript native;
  late TestApp app;

  setUp(() {
    native = FakeNativeTranscript.install();
    app = TestApp.create();
    addTearDown(app.dispose);
  });

  testWidgets("a document comes back as a reply's blocks, its formulas "
      "sent before them", (tester) async {
    await app.pump(tester, const SizedBox());
    final documents = ShellDocuments(
      app.container,
      () => tester.element(find.byType(SizedBox)),
    );
    final blocks = await io(
      tester,
      () => documents.markdown(
        "| Name | Mass |\n|:--|--:|\n| Earth | \$m_e\$ |\n\n"
        "1. one\n2. two\n\n> quoted\n\n---\n\n```dart\nvar x = 1;\n```",
        false,
      ),
    );

    final table = blocks.firstWhere((b) => b.kind == TextKind.table);
    expect(table.align, [CellAlign.start, CellAlign.end]);
    final formula = table.cells
        .expand((c) => c.inlines)
        .firstWhere((i) => i.kind == InlineKind.formula);
    expect(native.pictures.map((p) => p.id), contains(formula.formula));

    final items = blocks.where((b) => b.items.isNotEmpty).toList();
    expect(items.map((b) => b.items.single.ordered), [true, true]);
    expect(items.map((b) => b.items.single.number), [1, 2]);
    expect(blocks.where((b) => b.quotes > 0), hasLength(1));
    expect(blocks.where((b) => b.kind == TextKind.rule), hasLength(1));
    final code = blocks.singleWhere((b) => b.kind == TextKind.code);
    expect(code.tokens.length, greaterThan(1));
  });
}
