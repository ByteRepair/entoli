import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/provider_edit.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../widgets/environment_section.dart";
import "cli_sign_in_dialog.dart" show CliAccountSection;

/// Add or edit one endpoint the agent can call. A preset opens on the key
/// alone, in plain words, with its technical fields folded under Advanced;
/// a custom endpoint opens on all of them. Which technical fields those are
/// is the API's: an HTTP one is a base URL and a key, a CLI one a program,
/// its sign-in and the environment it runs with. Pops the draft to save, or
/// null where it was cancelled.
///
/// A typed key is put to the provider before the dialog closes; one it
/// refuses keeps it open, saying so, with Save turned into Save anyway.
class ProviderDialog extends ConsumerStatefulWidget {
  const ProviderDialog(this.edit, {super.key, this.encrypted = true});

  final ProviderEdit edit;

  /// Whether keys go to the OS keyring rather than the app's own store.
  final bool encrypted;

  @override
  ConsumerState<ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends ConsumerState<ProviderDialog> {
  ProviderEdit get _edit => widget.edit;

  late final _name = TextEditingController(text: _edit.name);
  late final _catalogId = TextEditingController(text: _edit.catalogId);
  late final _baseUrl = TextEditingController(text: _edit.baseUrl);
  final _apiKey = TextEditingController();
  late final _modelsEndpoint = TextEditingController(
    text: _edit.modelsEndpoint,
  );
  late final _command = TextEditingController(text: _edit.command);

  late final _terms = _edit.preset?.terms;
  late final _keyless = _edit.preset?.needsKey == false;
  late var _advanced = _terms == null;

  var _checking = false;

  /// The provider refused the key in the field. Typing clears it.
  var _rejected = false;

  @override
  void dispose() {
    for (final field in [
      _name,
      _catalogId,
      _baseUrl,
      _apiKey,
      _modelsEndpoint,
      _command,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  ProviderDraft get _draft =>
      (_edit
            ..name = _name.text
            ..key = _apiKey.text
            ..baseUrl = _baseUrl.text
            ..modelsEndpoint = _modelsEndpoint.text
            ..catalogId = _catalogId.text
            ..command = _command.text)
          .draft;

  Future<void> _save() async {
    final draft = _draft;
    if (!_rejected) {
      setState(() => _checking = true);
      final accepted = await checkProviderKey(
        ref.read(keyCheckProvider),
        draft,
      );
      if (!mounted) return;
      if (accepted == false) {
        setState(() {
          _checking = false;
          _rejected = true;
        });
        return;
      }
    }
    Navigator.pop(context, draft);
  }

  void _open(String url) =>
      ref.read(linkOpenerProvider).open(context, Uri.parse(url));

  @override
  Widget build(BuildContext context) {
    final terms = _terms;
    return AlertDialog(
      title: Text(_edit.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: _edit.adding && terms == null,
                onChanged: (text) => setState(() => _edit.name = text),
                decoration: InputDecoration(
                  labelText: "Name",
                  hintText: _edit.preset?.displayName,
                  helperText: "What the model list calls it",
                  errorText: _edit.nameError,
                ),
              ),
              const SizedBox(height: 16),
              if (terms != null && !_edit.api.isCli) ...[
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
              if (_advanced || terms == null || _edit.api.isCli)
                ..._technical(),
              if (_edit.storedKey != null && !_edit.api.isCli) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _apiKey.clear();
                    _edit.removeKey = true;
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
          onPressed: _checking || !_edit.canSave ? null : _save,
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

  /// What a preset needs from someone who does not know what a base URL is:
  /// the key, where to get one, and where the provider says what it does
  /// with the prompts. No technical word here; those are under Advanced.
  List<Widget> _basic(BuildContext context, PresetTerms terms) {
    final service = _edit.service;
    return [
      Text(
        _keyless
            ? "$service runs on this computer, so there is nothing to type. "
                  "Start $service before you chat."
            : "Entoli needs an access key from your $service account to talk "
                  "to it. Create one on $service's website, copy it, and "
                  "paste it below.",
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      if (terms.keyUrl case final url?) ...[
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text("Get a key from $service"),
          onPressed: () => _open(url),
        ),
      ],
      if (!_keyless) ...[
        const SizedBox(height: 16),
        _keyField(
          label: "Access key",
          helper: _edit.storedKey != null
              ? "Leave empty to keep the key you saved"
              : "Kept private on this device",
        ),
      ],
      if (terms.policy case final policy?) ...[
        const SizedBox(height: 8),
        TextButton(
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          onPressed: () => _open(policy),
          child: Text("$service's privacy policy"),
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
          if (_edit.removeKey && _apiKey.text.trim().isNotEmpty) {
            setState(() => _edit.removeKey = false);
          }
        },
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          errorText: _rejected ? keyRefused(_draft.config) : null,
          errorMaxLines: 2,
        ),
      );

  /// The whole entry, in the terms the endpoint itself uses. A preset's key
  /// field is above it, under its plain name, unless the preset is local: a
  /// local server can sit behind a key, so it is offered here.
  List<Widget> _technical() => [
    if (_edit.preset == null) ...[
      DropdownButtonFormField<LlmApi>(
        initialValue: _edit.api,
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
          // A program run here, a desktop's own or in Android's Linux, which
          // iOS cannot do; an entry synced onto it still shows what it is.
          for (final cli in cliProviderPresets)
            if (cli.supported || _edit.api == cli.config.api)
              DropdownMenuItem(
                value: cli.config.api,
                child: Text(cli.config.displayName),
              ),
        ],
        onChanged: (value) =>
            setState(() => _edit.api = value ?? LlmApi.openai),
      ),
      const SizedBox(height: 16),
    ],
    ...(_edit.api.isCli ? _cliFields() : _httpFields()),
  ];

  /// What a program run here is configured with: which program, its sign-in
  /// and what it runs under. No key: it holds its own sign-in.
  List<Widget> _cliFields() {
    final cli = cliPresetOf(_edit.api);
    return [
      Text(cli.about, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      // Keyed by the program, so switching the API asks the other one. Signed
      // in under the id the entry is saved with.
      CliAccountSection(key: ValueKey(_edit.api), config: _draft.config),
      const SizedBox(height: 16),
      TextField(
        controller: _command,
        decoration: InputDecoration(
          labelText: "Executable",
          hintText: cli.defaultCommand,
          helperText: "Empty runs ${cli.defaultCommand} from PATH",
          suffixIcon: IconButton(
            tooltip: "Choose a file",
            icon: const Icon(Icons.folder_open),
            onPressed: _chooseExecutable,
          ),
        ),
      ),
      const SizedBox(height: 16),
      EnvironmentSection(
        env: _edit.env,
        description: "What the program runs with, over the app's own.",
        onSaved: (next) async => setState(() => _edit.env = next),
      ),
    ];
  }

  Future<void> _chooseExecutable() async {
    final file = await openFile(confirmButtonText: "Use this program");
    if (file == null || !mounted) return;
    setState(() => _command.text = file.path);
  }

  /// What an endpoint reached over HTTP is configured with.
  List<Widget> _httpFields() {
    final stored = _edit.storedKey != null;
    final env = (_edit.provider ?? _edit.preset?.config)?.apiKeyEnv;
    return [
      TextField(
        controller: _baseUrl,
        onChanged: (text) => setState(() => _edit.baseUrl = text),
        decoration: InputDecoration(
          labelText: "Base URL",
          hintText: _edit.preset?.config.baseUrl,
          helperText: "The versioned root, e.g. https://api.openai.com/v1",
        ),
      ),
      if (_terms == null || _keyless) ...[
        const SizedBox(height: 16),
        _keyField(
          label: "API key",
          helper: stored
              ? "Leave empty to keep the stored key"
              : env == null
              ? "Stored in the ${widget.encrypted ? "OS keyring" : "app secret store"}"
              : "Leave empty to read \$$env from the environment",
        ),
      ] else if (env != null && !stored) ...[
        const SizedBox(height: 8),
        Text(
          "With the access key left empty, \$$env is read from the "
          "environment.",
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
        decoration: InputDecoration(
          labelText: "Provider ID",
          hintText: _edit.preset?.config.catalogId,
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
