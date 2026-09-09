import "package:flutter/material.dart";

import "../../domain/llm_provider.dart";

/// Add or edit one endpoint the agent can call. Returns null if dismissed, or
/// if the name or base URL was left blank — either one missing makes the entry
/// unusable, and a half-written provider fails at the first prompt rather than
/// here. The key decision rides beside it as the notifier's own [setKey]
/// encoding — null leaves the stored key, `""` clears it, a string stores it —
/// because the dialog cannot decide keep against clear from an empty field
/// alone, and the store is written by the caller's notifier, not by this
/// dialog.
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
  const ProviderEdit(this.config, this.setKey);

  final LlmProviderConfig config;

  /// Null keeps the stored key, `""` clears it, a string stores itself.
  final String? setKey;
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

  /// The key decision in the notifier's own encoding: typed text stores,
  /// the "Remove stored key" press clears, and an empty field otherwise keeps
  /// — over no stored key, clearing is the honest answer, so a key saved since
  /// the dialog opened is not resurrected by a save that typed nothing.
  String? get _setKey {
    final text = _apiKey.text.trim();
    if (text.isNotEmpty) return text;
    if (_clearKey) return "";
    return widget.storedKey == null ? "" : null;
  }

  ProviderEdit? _submit() {
    final id = _id.text.trim();
    final baseUrl = _baseUrl.text.trim();
    if (id.isEmpty || baseUrl.isEmpty) return null;
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
      _setKey,
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
