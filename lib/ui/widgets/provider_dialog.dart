import "package:flutter/material.dart";

import "../../domain/llm_provider.dart";

/// How a provider's stored key changes, returned beside the config. The dialog
/// cannot decide keep against clear from an empty field alone — the field
/// starts empty when a key is stored, which used to mean "keep" and still
/// means "none stored" — so the three answers are spelled.
enum KeyChange {
  /// Leave whatever is stored as it is.
  keep,

  /// Remove the stored key.
  clear,

  /// Store the text the field held.
  set,
}

/// Add or edit one endpoint the agent can call. Returns null if dismissed, or
/// if the name or base URL was left blank — either one missing makes the entry
/// unusable, and a half-written provider fails at the first prompt rather than
/// here. The key rides beside it as a [KeyChange], because the store it goes
/// to is written by the caller's notifier, not by this dialog.
Future<ProviderEdit?> promptForProvider(
  BuildContext context, {
  LlmProviderConfig? initial,
  String? storedKey,
  bool encrypted = false,
  String title = "Add provider",
}) =>
    showDialog<ProviderEdit>(
      context: context,
      builder: (context) => _ProviderDialog(
        initial: initial,
        storedKey: storedKey,
        encrypted: encrypted,
        title: title,
      ),
    );

class ProviderEdit {
  const ProviderEdit(this.config, this.key, {this.typedKey});

  final LlmProviderConfig config;
  final KeyChange key;

  /// What the field held when [key] is [KeyChange.set] — the config's own
  /// `apiKey` is left empty, the store being where the material goes.
  final String? typedKey;
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({
    required this.initial,
    required this.storedKey,
    required this.encrypted,
    required this.title,
  });

  final LlmProviderConfig? initial;
  final String? storedKey;
  final bool encrypted;
  final String title;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final _id = TextEditingController(text: widget.initial?.id ?? "");
  late final _baseUrl = TextEditingController(text: widget.initial?.baseUrl ?? "");
  late final _apiKey = TextEditingController();
  late final _models = TextEditingController(text: widget.initial?.models.join(", ") ?? "");
  late var _api = widget.initial?.api ?? LlmApi.openai;

  /// The "Remove stored key" press. Typed text overrides it — clearing and
  /// then typing is a replace, not a remove — and Save without either is the
  /// keep case.
  var _clearKey = false;

  @override
  void dispose() {
    _id.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _models.dispose();
    super.dispose();
  }

  KeyChange get _keyChange {
    final text = _apiKey.text.trim();
    if (text.isNotEmpty) return KeyChange.set;
    if (_clearKey) return KeyChange.clear;
    // An empty field over a stored key is the keep case — the user was shown
    // "leave empty to keep" and typed nothing. Over no stored key it is the
    // clear case of nothing, and answers clear so a cleared field beside a
    // key saved since the dialog opened does not resurrect it.
    return widget.storedKey == null ? KeyChange.clear : KeyChange.keep;
  }

  ProviderEdit? _submit() {
    final id = _id.text.trim();
    final baseUrl = _baseUrl.text.trim();
    if (id.isEmpty || baseUrl.isEmpty) return null;
    final typed = _apiKey.text.trim();
    return ProviderEdit(
      LlmProviderConfig(
        id: id,
        api: _api,
        baseUrl: baseUrl,
        label: widget.initial?.label,
        apiKeyEnv: widget.initial?.apiKeyEnv,
        defaultModelId: widget.initial?.defaultModelId,
        defaultLightModelId: widget.initial?.defaultLightModelId,
        models: [
          for (final model in _models.text.split(RegExp(r"[,\n]")))
            if (model.trim().isNotEmpty) model.trim(),
        ],
      ),
      _keyChange,
      typedKey: typed.isEmpty ? null : typed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasStoredKey = widget.storedKey != null;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _id,
                autofocus: widget.initial == null,
                decoration: const InputDecoration(
                  labelText: "Name",
                  helperText: "How the model list refers to it, e.g. openrouter",
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<LlmApi>(
                initialValue: _api,
                isExpanded: true,
                decoration: const InputDecoration(labelText: "API"),
                items: const [
                  DropdownMenuItem(value: LlmApi.openai, child: Text("OpenAI-compatible")),
                  DropdownMenuItem(value: LlmApi.anthropic, child: Text("Anthropic")),
                ],
                onChanged: (value) => setState(() => _api = value ?? LlmApi.openai),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: "Base URL",
                  helperText: "The versioned root, e.g. https://api.openai.com/v1",
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiKey,
                obscureText: true,
                onChanged: (_) {
                  if (_clearKey && _apiKey.text.trim().isNotEmpty) {
                    setState(() => _clearKey = false);
                  }
                },
                decoration: InputDecoration(
                  labelText: "API key",
                  helperText: hasStoredKey
                      ? "Leave empty to keep the stored key"
                      : widget.initial?.apiKeyEnv == null
                          ? "Stored in the ${widget.encrypted ? "OS keyring" : "app secret store"}"
                          : "Leave empty to read \$${widget.initial!.apiKeyEnv} from the environment",
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _models,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: "Models",
                  helperText: "Comma-separated. Leave empty to ask the endpoint.",
                ),
              ),
              if (hasStoredKey) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _apiKey.clear();
                    _clearKey = true;
                  }),
                  child: const Text("Remove stored key"),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(
          onPressed: () => Navigator.pop(context, _submit()),
          child: const Text("Save"),
        ),
      ],
    );
  }
}