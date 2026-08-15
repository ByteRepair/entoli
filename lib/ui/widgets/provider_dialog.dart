import "package:flutter/material.dart";

import "../../domain/llm_provider.dart";

/// Add or edit one endpoint the built-in harness can call. Returns null if
/// dismissed, or if the name or base URL was left blank — either one missing
/// makes the entry unusable, and a half-written provider fails at the first
/// prompt rather than here.
Future<LlmProviderConfig?> promptForProvider(
  BuildContext context, {
  LlmProviderConfig? initial,
  String title = "Add provider",
}) =>
    showDialog<LlmProviderConfig>(
      context: context,
      builder: (context) => _ProviderDialog(initial: initial, title: title),
    );

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({required this.initial, required this.title});

  final LlmProviderConfig? initial;
  final String title;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final _id = TextEditingController(text: widget.initial?.id ?? "");
  late final _baseUrl = TextEditingController(text: widget.initial?.baseUrl ?? "");
  late final _apiKey = TextEditingController(text: widget.initial?.apiKey ?? "");
  late final _models = TextEditingController(text: widget.initial?.models.join(", ") ?? "");
  late var _api = widget.initial?.api ?? LlmApi.openai;

  @override
  void dispose() {
    _id.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _models.dispose();
    super.dispose();
  }

  LlmProviderConfig? _submit() {
    final id = _id.text.trim();
    final baseUrl = _baseUrl.text.trim();
    if (id.isEmpty || baseUrl.isEmpty) return null;
    return LlmProviderConfig(
      id: id,
      api: _api,
      baseUrl: baseUrl,
      label: widget.initial?.label,
      apiKey: _apiKey.text.trim(),
      apiKeyEnv: widget.initial?.apiKeyEnv,
      models: [
        for (final model in _models.text.split(RegExp(r"[,\n]")))
          if (model.trim().isNotEmpty) model.trim(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<LlmApi>(
                initialValue: _api,
                decoration: const InputDecoration(
                  labelText: "API",
                  border: OutlineInputBorder(),
                ),
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
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "API key",
                  helperText: widget.initial?.apiKeyEnv == null
                      ? "Stored in settings.json"
                      : "Leave empty to read \$${widget.initial!.apiKeyEnv} from the environment",
                  border: const OutlineInputBorder(),
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
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Keys are stored in plain text in settings.json.",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
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
