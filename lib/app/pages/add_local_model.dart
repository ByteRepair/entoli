import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../../providers.dart";
import "../downloads/model_downloads.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// An on-device model added by its link rather than picked from the
/// catalog: a `.gguf`, what it is called and published under, and the hash
/// it is checked against where one is given. Download adds it and starts
/// fetching it.
class AddLocalModelAppPage extends AppPage {
  String _url = "";
  String _name = "";
  String _parameters = "";
  String _licence = "";
  String _sha256 = "";

  @override
  String get address => "add-local-model";

  @override
  String title(SettingReader reader) => "Add Model";

  String? get _urlError {
    final text = _url.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    return uri == null ||
            !uri.isScheme("https") && !uri.isScheme("http") ||
            uri.host.isEmpty
        ? "A link starting with https://"
        : null;
  }

  String? get _shaError {
    final text = _sha256.trim();
    return text.isEmpty || RegExp(r"^[0-9a-fA-F]{64}$").hasMatch(text)
        ? null
        : "64 hexadecimal characters";
  }

  bool get _ready =>
      _url.trim().isNotEmpty && _urlError == null && _shaError == null;

  TextController _field(
    String id,
    String title,
    String value,
    void Function(String) set, {
    String? help,
    String? error,
  }) => TextController(
    part(id, title, hint: UiHint.input, description: error ?? help),
    value: value,
    prompt: title,
    allowBlank: true,
    onSet: (text) async {
      set(text);
      changed();
      return null;
    },
  );

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("model", "", [
      _field(
        "url",
        "Link",
        _url,
        (v) => _url = v,
        help: "To a .gguf file, e.g. a Hugging Face \"resolve\" link",
        error: _urlError,
      ),
      _field(
        "name",
        "Name",
        _name,
        (v) => _name = v,
        help: "Empty takes the one inside the file",
      ),
      _field(
        "parameters",
        "Parameters",
        _parameters,
        (v) => _parameters = v,
        help: "As the publisher writes it, e.g. 4B",
      ),
      _field("licence", "Licence", _licence, (v) => _licence = v),
      _field(
        "sha256",
        "SHA-256",
        _sha256,
        (v) => _sha256 = v,
        help: "Checked before the file is kept, where given",
        error: _shaError,
      ),
    ]),
  ];

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    ActionController(
      part("download", "Download"),
      label: "Download",
      enabled: _ready,
      run: () async {
        String? optional(String text) =>
            text.trim().isEmpty ? null : text.trim();
        final url = _url.trim();
        final engine = app.read(localEngineProvider);
        final taken = {
          for (final model in engine.catalog) model.id,
          for (final model in app.read(addedLocalModelsProvider)) model.id,
          ...app.read(installedLocalModelsProvider),
        };
        final model = engine.fromLink!((
          id: localModelIdFor(url, taken),
          name: _name.trim(),
          url: url,
          parameters: optional(_parameters),
          licence: optional(_licence),
          sha256: optional(_sha256),
        ));
        app.read(addedLocalModelsProvider.notifier).add(model);
        app
            .read(modelDownloadsProvider.notifier)
            .install(InstallableLocalModel(model, engine.store));
        app.read(appPagesProvider.notifier).leave(this);
        return null;
      },
    ),
  ];
}
