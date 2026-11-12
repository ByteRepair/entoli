import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../../providers.dart";
import "../../app/downloads/model_downloads.dart";
import "../widgets/page_bar.dart";

/// A model from any link to a GGUF. Only the link is needed: what the server
/// needs is read off the file once it has arrived, and the rest is what the
/// row will say about it.
class AddLocalModelPage extends ConsumerStatefulWidget {
  const AddLocalModelPage({super.key});

  @override
  ConsumerState<AddLocalModelPage> createState() => _AddLocalModelPageState();
}

class _AddLocalModelPageState extends ConsumerState<AddLocalModelPage> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _parameters = TextEditingController();
  final _licence = TextEditingController();
  final _sha256 = TextEditingController();

  @override
  void dispose() {
    for (final field in [_url, _name, _parameters, _licence, _sha256]) {
      field.dispose();
    }
    super.dispose();
  }

  String? get _urlError {
    final text = _url.text.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    return uri == null ||
            !uri.isScheme("https") && !uri.isScheme("http") ||
            uri.host.isEmpty
        ? "A link starting with https://"
        : null;
  }

  String? get _shaError {
    final text = _sha256.text.trim();
    return text.isEmpty || RegExp(r"^[0-9a-fA-F]{64}$").hasMatch(text)
        ? null
        : "64 hexadecimal characters";
  }

  bool get _ready =>
      _url.text.trim().isNotEmpty && _urlError == null && _shaError == null;

  void _add() {
    String? optional(TextEditingController field) =>
        field.text.trim().isEmpty ? null : field.text.trim();
    final url = _url.text.trim();
    final taken = {
      for (final model in ref.read(localEngineProvider).catalog) model.id,
      for (final model in ref.read(addedLocalModelsProvider)) model.id,
      ...ref.read(installedLocalModelsProvider),
    };
    final engine = ref.read(localEngineProvider);
    final model = engine.fromLink!((
      id: localModelIdFor(url, taken),
      name: _name.text.trim(),
      url: url,
      parameters: optional(_parameters),
      licence: optional(_licence),
      sha256: optional(_sha256),
    ));
    ref.read(addedLocalModelsProvider.notifier).add(model);
    ref
        .read(modelDownloadsProvider.notifier)
        .install(InstallableLocalModel(model, engine.store));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    TextField field(
      TextEditingController controller,
      String label, {
      String? helper,
      String? error,
      bool autofocus = false,
    }) => TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        errorText: error,
      ),
    );
    return Scaffold(
      appBar: PageBar(title: "Add model"),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          field(
            _url,
            "Link",
            helper: "To a .gguf file, e.g. a Hugging Face \"resolve\" link",
            error: _urlError,
            autofocus: true,
          ),
          const SizedBox(height: 16),
          field(_name, "Name", helper: "Empty takes the one inside the file"),
          const SizedBox(height: 16),
          field(
            _parameters,
            "Parameters",
            helper: "As the publisher writes it, e.g. 4B",
          ),
          const SizedBox(height: 16),
          field(_licence, "Licence"),
          const SizedBox(height: 16),
          field(
            _sha256,
            "SHA-256",
            helper: "Checked before the file is kept, where given",
            error: _shaError,
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _ready ? _add : null,
              child: const Text("Download"),
            ),
          ),
        ],
      ),
    );
  }
}
