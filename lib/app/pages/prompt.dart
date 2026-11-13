import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A [PromptController]'s text on a page of its own, the editor the whole
/// of it: kept as a draft and handed back by Save, the page that opened it
/// holding it until that page's own save.
class PromptAppPage extends AppPage {
  PromptAppPage({
    required this.from,
    required this.heading,
    required String text,
    required this.placeholder,
    required this.onSave,
  }) : _opened = text,
       _draft = text;

  /// The id of the field that opened it, which it is addressed under.
  final String from;
  final String heading;
  final String placeholder;
  final void Function(String text) onSave;

  final String _opened;
  String _draft;

  bool get _edited => _draft != _opened;

  @override
  String get address => "prompt/$from";

  @override
  String title(SettingReader reader) => heading;

  @override
  SettingConfirm? leaving(SettingReader reader) =>
      _edited ? AppPage.discardChanges : null;

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection.whole(
      "text",
      DocumentController(
        part("text", heading),
        text: _draft,
        // Highlighted as what it is read as.
        name: "instructions.md",
        editing: true,
        placeholder: placeholder,
        onEdit: (text) {
          final was = _edited;
          _draft = text;
          if (was != _edited) changed();
        },
      ),
    ),
  ];

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    ActionController(
      part("save", "Save", glyph: SettingGlyph.check),
      run: () async {
        onSave(_draft);
        pages.leave(this);
        return null;
      },
    ),
  ];
}

/// A field of a page's that is a [PromptController].
extension PromptFields on AppPage {
  /// [text] previewed as it will be read, a tap opening the editor over
  /// this page; Save there hands the text to [onSet].
  PromptController prompt(
    String id,
    String title, {
    required String text,
    required String placeholder,
    required void Function(String text) onSet,
    String? description,
  }) => PromptController(
    part(id, title, description: description),
    text: text,
    placeholder: placeholder,
    onOpen: () async => pages.open(
      PromptAppPage(
        from: "$address/$id",
        heading: title,
        text: text,
        placeholder: placeholder,
        onSave: onSet,
      ),
    ),
  );
}
