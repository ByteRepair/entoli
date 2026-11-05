import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";

import "../../core/log.dart";
import "../../core/platform/form_factor.dart";
import "../../data/builtin/llm/llm_client.dart" show LlmException;
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "environment_section.dart";

/// Add or edit one endpoint the agent can call. A preset opens on the key
/// alone, in plain words, with its technical fields folded under Advanced;
/// a custom endpoint opens on all of them. Which technical fields those are
/// is the API's: an HTTP one is a base URL and a key, a CLI one a program
/// and the environment it runs with. The name is asked of both, and
/// Save waits until it is one [nameTaken] says no other provider has. Returns null if
/// dismissed, or if the base URL was left blank — a half-written provider
/// fails at the first prompt rather than here. The key decision rides beside
/// it as the notifier's own [setKey] encoding — null leaves the stored key, `""` clears it, a string stores it —
/// because the dialog cannot decide keep against clear from an empty field
/// alone, and the store is written by the caller's notifier, not by this
/// dialog.
///
/// A typed key is put to [checkKey] before the dialog closes; one the provider
/// refuses keeps it open, saying so, with Save turned into Save anyway. One it
/// could not be asked about is saved: no answer is not a no.
Future<ProviderEdit?> promptForProvider(
  BuildContext context, {
  LlmProviderConfig? initial,
  String? storedKey,
  bool Function(String name)? nameTaken,
  bool encrypted = false,
  String title = "Add provider",
  void Function(BuildContext, Uri)? openLink,
  Future<bool> Function(LlmProviderConfig config, String apiKey)? checkKey,
}) => showDialog<ProviderEdit>(
  context: context,
  builder: (context) => _ProviderDialog(
    initial: initial,
    storedKey: storedKey,
    nameTaken: nameTaken,
    encrypted: encrypted,
    title: title,
    openLink: openLink,
    checkKey: checkKey,
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
    required this.nameTaken,
    required this.encrypted,
    required this.title,
    required this.openLink,
    required this.checkKey,
  });

  final LlmProviderConfig? initial;
  final String? storedKey;
  final bool Function(String name)? nameTaken;
  final bool encrypted;
  final String title;
  final void Function(BuildContext, Uri)? openLink;
  final Future<bool> Function(LlmProviderConfig config, String apiKey)?
  checkKey;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final _name = TextEditingController(
    text: widget.initial?.displayName ?? "",
  );
  late final _catalogId = TextEditingController(
    text: widget.initial?.catalogId ?? "",
  );
  late final _baseUrl = TextEditingController(
    text: widget.initial?.baseUrl ?? "",
  );
  late final _apiKey = TextEditingController();
  late final _modelsEndpoint = TextEditingController(
    text: widget.initial?.modelsEndpoint ?? "",
  );
  late var _api = widget.initial?.api ?? LlmApi.openai;
  late final _command = TextEditingController(
    text: widget.initial?.command ?? "",
  );
  late var _env = {...?widget.initial?.env};

  /// Non-null for a provider with a class of its own, which opens on the key
  /// alone; a custom endpoint is nothing but the technical fields, so it opens
  /// on them.
  late final _provider = widget.initial == null
      ? null
      : providerOf(widget.initial!);
  late final _terms = _provider?.terms;
  late final _keyless = _provider?.needsKey == false;
  late var _advanced = _terms == null;

  var _checking = false;

  /// The provider refused the key in the field. Typing clears it.
  var _rejected = false;

  /// The "Remove saved key" press. Typed text overrides it — clearing and
  /// then typing is a replace, not a remove — and Save without either is the
  /// keep case.
  var _clearKey = false;

  @override
  void dispose() {
    _name.dispose();
    _catalogId.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _modelsEndpoint.dispose();
    _command.dispose();
    super.dispose();
  }

  /// The key decision in the notifier's own encoding: typed text stores,
  /// the "Remove saved key" press clears, and an empty field otherwise keeps
  /// — over no stored key, clearing is the honest answer, so a key saved since
  /// the dialog opened is not resurrected by a save that typed nothing.
  String? get _setKey {
    final text = _apiKey.text.trim();
    if (text.isNotEmpty) return text;
    if (_clearKey) return "";
    return widget.storedKey == null ? "" : null;
  }

  /// Another provider already has the name typed.
  bool get _nameTaken => widget.nameTaken?.call(_name.text) ?? false;

  bool get _nameOk => _name.text.trim().isNotEmpty && !_nameTaken;

  ProviderEdit? _submit() {
    if (_api.isCli) {
      final command = _command.text.trim();
      return ProviderEdit(
        LlmProviderConfig(
          id: widget.initial?.id ?? "",
          api: _api,
          baseUrl: "",
          name: _name.text.trim(),
          defaultModelId:
              widget.initial?.defaultModelId ??
              ClaudeCliProvider.preset.defaultModelId,
          defaultLightModelId:
              widget.initial?.defaultLightModelId ??
              ClaudeCliProvider.preset.defaultLightModelId,
          customModels: widget.initial?.customModels ?? const [],
          command: command.isEmpty ? null : command,
          env: _env,
        ),
        // A program holds its own sign-in; whatever was stored stays put.
        null,
      );
    }
    final baseUrl = _baseUrl.text.trim();
    final modelsEndpoint = _modelsEndpoint.text.trim();
    final catalogId = _catalogId.text.trim();
    if (baseUrl.isEmpty) return null;
    return ProviderEdit(
      LlmProviderConfig(
        id: widget.initial?.id ?? "",
        api: _api,
        baseUrl: baseUrl,
        name: _name.text.trim(),
        catalogId: catalogId.isEmpty ? null : catalogId,
        apiKeyEnv: widget.initial?.apiKeyEnv,
        defaultModelId: widget.initial?.defaultModelId,
        defaultLightModelId: widget.initial?.defaultLightModelId,
        customModels: widget.initial?.customModels ?? const [],
        modelsEndpoint: modelsEndpoint.isEmpty ? null : modelsEndpoint,
      ),
      _setKey,
    );
  }

  void _open(String url) => widget.openLink?.call(context, Uri.parse(url));

  /// What a preset needs from someone who does not know what a base URL is:
  /// the key, where to get one, and where the provider says what it does
  /// with the prompts. No technical word here; those are under Advanced.
  List<Widget> _basic(BuildContext context, PresetTerms terms) {
    final textTheme = Theme.of(context).textTheme;
    return [
      Text(
        _keyless
            ? "$_service runs on this computer, so there is nothing to type. "
                  "Start $_service before you chat."
            : "Entoli needs an access key from your $_service account to talk "
                  "to it. Create one on $_service's website, copy it, and paste it "
                  "below.",
        style: textTheme.bodyMedium,
      ),
      if (terms.keyUrl != null) ...[
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text("Get a key from $_service"),
          onPressed: () => _open(terms.keyUrl!),
        ),
      ],
      if (!_keyless) ...[
        const SizedBox(height: 16),
        _keyField(
          label: "Access key",
          helper: widget.storedKey != null
              ? "Leave empty to keep the key you saved"
              : "Kept private on this device",
        ),
      ],
      if (terms.policy != null) ...[
        const SizedBox(height: 8),
        TextButton(
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          onPressed: () => _open(terms.policy!),
          child: Text("$_service's privacy policy"),
        ),
      ],
    ];
  }

  Widget _keyField({required String label, required String helper}) =>
      TextField(
        controller: _apiKey,
        obscureText: true,
        autofocus: _terms != null,
        onChanged: (_) {
          if (_rejected) setState(() => _rejected = false);
          if (_clearKey && _apiKey.text.trim().isNotEmpty) {
            setState(() => _clearKey = false);
          }
        },
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          errorText: _rejected
              ? "$_service did not accept this key. Check "
                    "it was copied whole."
              : null,
          errorMaxLines: 2,
        ),
      );

  /// The preset's own name, which the plain words are about whatever the
  /// entry is called.
  late final String _service =
      (widget.initial == null
          ? null
          : presetOf(widget.initial!)?.displayName) ??
      "The provider";

  Future<void> _save() async {
    final edit = _submit();
    final key = edit?.setKey;
    final check = widget.checkKey;
    if (edit == null ||
        key == null ||
        key.isEmpty ||
        check == null ||
        _rejected) {
      Navigator.pop(context, edit);
      return;
    }
    setState(() => _checking = true);
    bool? accepted;
    try {
      accepted = await check(edit.config, key);
    } on LlmException catch (e) {
      logFailure("llm", "checking ${edit.config.id}'s key failed", e);
    }
    if (!mounted) return;
    if (accepted == false) {
      setState(() {
        _checking = false;
        _rejected = true;
      });
      return;
    }
    Navigator.pop(context, edit);
  }

  @override
  Widget build(BuildContext context) {
    final hasStoredKey = widget.storedKey != null;
    final terms = _terms;
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
                controller: _name,
                autofocus: widget.initial == null,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: "Name",
                  helperText: "What the model list calls it",
                  errorText: _nameTaken
                      ? "Another provider is called ${_name.text.trim()}"
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              if (terms != null) ...[
                ..._basic(context, terms),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    icon: Icon(
                      _advanced ? Icons.expand_less : Icons.expand_more,
                    ),
                    label: const Text("Advanced"),
                    onPressed: () => setState(() => _advanced = !_advanced),
                  ),
                ),
              ],
              if (_advanced) ..._technical(hasStoredKey),
              if (hasStoredKey && !_api.isCli) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _apiKey.clear();
                    _clearKey = true;
                  }),
                  child: const Text("Remove saved key"),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: _checking || !_nameOk ? null : _save,
          child: _checking
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_rejected ? "Save anyway" : "Save"),
        ),
      ],
    );
  }

  /// The whole entry, in the terms the endpoint itself uses. A preset's key
  /// field is above it, under its plain name, unless the preset is local — a
  /// local server can sit behind a key, so it is offered here.
  List<Widget> _technical(bool hasStoredKey) => [
    DropdownButtonFormField<LlmApi>(
      initialValue: _api,
      isExpanded: true,
      decoration: const InputDecoration(labelText: "API"),
      items: [
        const DropdownMenuItem(
          value: LlmApi.openai,
          child: Text("OpenAI-compatible"),
        ),
        const DropdownMenuItem(
          value: LlmApi.anthropic,
          child: Text("Anthropic"),
        ),
        // A program run here, which a phone cannot do; an entry synced onto
        // one still shows what it is.
        if (isDesktop || _api.isCli)
          const DropdownMenuItem(
            value: LlmApi.claudeCli,
            child: Text("Claude CLI"),
          ),
      ],
      onChanged: (value) => setState(() => _api = value ?? LlmApi.openai),
    ),
    const SizedBox(height: 16),
    ...(_api.isCli ? _cliFields() : _httpFields(hasStoredKey)),
  ];

  /// What a program run here is configured with: which program, and what
  /// it runs under. No key: it holds its own sign-in.
  List<Widget> _cliFields() => [
    Text(ClaudeCliProvider.about, style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 16),
    TextField(
      controller: _command,
      decoration: InputDecoration(
        labelText: "Executable",
        hintText: "claude",
        helperText: "Empty runs claude from PATH",
        suffixIcon: IconButton(
          tooltip: "Choose a file",
          icon: const Icon(Icons.folder_open),
          onPressed: _chooseExecutable,
        ),
      ),
    ),
    const SizedBox(height: 16),
    EnvironmentSection(
      env: _env,
      description: "What the program runs with, over the app's own.",
      onSaved: (next) async => setState(() => _env = next),
    ),
  ];

  Future<void> _chooseExecutable() async {
    final file = await openFile(confirmButtonText: "Use this program");
    if (file == null || !mounted) return;
    setState(() => _command.text = file.path);
  }

  /// What an endpoint reached over HTTP is configured with.
  List<Widget> _httpFields(bool hasStoredKey) {
    return [
      TextField(
        controller: _baseUrl,
        decoration: const InputDecoration(
          labelText: "Base URL",
          helperText: "The versioned root, e.g. https://api.openai.com/v1",
        ),
      ),
      if (_terms == null || _keyless) ...[
        const SizedBox(height: 16),
        _keyField(
          label: "API key",
          helper: hasStoredKey
              ? "Leave empty to keep the stored key"
              : widget.initial?.apiKeyEnv == null
              ? "Stored in the ${widget.encrypted ? "OS keyring" : "app secret store"}"
              : "Leave empty to read \$${widget.initial!.apiKeyEnv} from the environment",
        ),
      ] else if (widget.initial?.apiKeyEnv != null && !hasStoredKey) ...[
        const SizedBox(height: 8),
        Text(
          "With the access key left empty, \$${widget.initial!.apiKeyEnv} "
          "is read from the environment.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _modelsEndpoint,
        decoration: const InputDecoration(
          labelText: "Models endpoint",
          helperText:
              "Empty lists the models models.dev has for it. Filled, "
              "lists this endpoint's instead, e.g. "
              "http://localhost:11434/v1/models.",
          helperMaxLines: 3,
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _catalogId,
        decoration: const InputDecoration(
          labelText: "Provider ID",
          helperText:
              "Its id on models.dev, which lists its models when the "
              "models endpoint is empty, e.g. google. Empty matches it by "
              "base URL.",
          helperMaxLines: 3,
        ),
      ),
    ];
  }
}
