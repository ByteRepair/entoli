import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/custom_model.dart";
import "../../app/model_role.dart";
import "../../app/reader.dart";
import "discard_guard.dart";
import "page_bar.dart";

/// [draft] as a page: the model's facts, what it is, and what it can do.
/// Pops true once saved.
class CustomModelPage extends ConsumerStatefulWidget {
  const CustomModelPage(this.draft, {super.key});

  final CustomModelDraft draft;

  @override
  ConsumerState<CustomModelPage> createState() => _CustomModelPageState();
}

class _CustomModelPageState extends ConsumerState<CustomModelPage> {
  CustomModelDraft get _draft => widget.draft;
  var _saving = false;
  String? _failed;

  static const _caps = {
    ModelCap.toolCall: (
      "Tool calling",
      "Required for agentic use: without it, the model is not offered for "
          "chats",
    ),
    ModelCap.reasoning: ("Reasoning", null),
    ModelCap.readsImages: (
      "Sees images",
      "Images are sent to it rather than named",
    ),
    ModelCap.readsPdfs: (
      "Reads PDFs",
      "PDFs are sent to it, where the provider takes them",
    ),
    ModelCap.makesImages: ("Makes images", null),
  };

  void _edit(void Function() change) => setState(() {
    change();
    _failed = null;
  });

  Future<void> _save() async {
    if (_saving || !_draft.ready) return;
    setState(() => _saving = true);
    try {
      await saveCustomModel(WidgetReader(ref), _draft);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _failed = "$e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _text(
    String label,
    String value,
    void Function(String) set, {
    String? helper,
    String? error,
    bool focused = false,
  }) => TextFormField(
    initialValue: value,
    autofocus: focused,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      errorText: error,
    ),
    onChanged: (text) => _edit(() => set(text)),
    onFieldSubmitted: (_) => unawaited(_save()),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _draft;
    final error = TextStyle(color: theme.colorScheme.error);
    const gap = SizedBox(height: 12);
    return DiscardGuard(
      edited: () => d.edited,
      child: Scaffold(
        appBar: PageBar(
          title: d.isNew ? "Add model" : "Edit model",
          actions: [
            PageAction.text(
              label: "Save",
              onPressed: d.ready && !_saving ? () => unawaited(_save()) : null,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              "For a model models.dev does not list: a fine-tune, a private "
              "deployment. Entoli trusts what you enter here, so take it "
              "from the provider's documentation.",
              style: theme.textTheme.bodyMedium,
            ),
            gap,
            DropdownButtonFormField<String>(
              initialValue: d.provider.isEmpty ? null : d.provider,
              isExpanded: true,
              decoration: const InputDecoration(labelText: "Provider"),
              items: [
                for (final (id, name) in d.providers)
                  DropdownMenuItem(value: id, child: Text(name)),
              ],
              onChanged: (id) {
                if (id != null) _edit(() => d.provider = id);
              },
            ),
            gap,
            _text(
              "Model id",
              d.id,
              (t) => d.id = t,
              helper: "Exactly as the provider's API names it",
              focused: d.isNew,
            ),
            gap,
            _text("Display name (optional)", d.name, (t) => d.name = t),
            gap,
            _text(
              "Context window",
              d.context,
              (t) => d.context = t,
              helper: "Tokens",
              error: CustomModelDraft.notNumber(d.context),
            ),
            gap,
            _text(
              "Max output",
              d.output,
              (t) => d.output = t,
              helper: "Tokens",
              error: CustomModelDraft.notNumber(d.output),
            ),
            gap,
            _text(
              "Input price",
              d.inputCost,
              (t) => d.inputCost = t,
              helper: r"$ per million tokens",
              error: CustomModelDraft.notNumber(d.inputCost, decimal: true),
            ),
            gap,
            _text(
              "Output price",
              d.outputCost,
              (t) => d.outputCost = t,
              helper: r"$ per million tokens",
              error: CustomModelDraft.notNumber(d.outputCost, decimal: true),
            ),
            gap,
            Text("It is", style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            SegmentedButton<ModelRole>(
              segments: const [
                ButtonSegment(value: ModelRole.text, label: Text("Chat")),
                ButtonSegment(
                  value: ModelRole.transcription,
                  label: Text("Transcribes"),
                ),
                ButtonSegment(value: ModelRole.speech, label: Text("Speaks")),
              ],
              selected: {d.kind},
              onSelectionChanged: (picked) =>
                  _edit(() => d.kind = picked.first),
            ),
            gap,
            if (!d.chat)
              Text(
                d.kind == ModelRole.transcription
                    ? "Called at /audio/transcriptions, for voice mode's "
                          "listening."
                    : "Called at /audio/speech, for voice mode's speaking.",
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text("What it can do", style: theme.textTheme.titleSmall),
              for (final MapEntry(key: cap, value: (label, help))
                  in _caps.entries)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: help == null ? null : Text(help),
                  value: d.caps.contains(cap),
                  onChanged: (on) => _edit(
                    () => d.caps = {
                      for (final c in d.caps)
                        if (c != cap) c,
                      if (on) cap,
                    },
                  ),
                ),
              if (!d.caps.contains(ModelCap.toolCall))
                Text(
                  "Without tool calling it is not offered for chats.",
                  style: error,
                ),
              if (d.role == ModelRole.image &&
                  !d.caps.contains(ModelCap.makesImages)) ...[
                gap,
                const Text(
                  "It will not be offered as an image model unless it makes "
                  "images.",
                ),
              ],
            ],
            if (_failed case final failed?) ...[
              const SizedBox(height: 16),
              Text(failed, style: error),
            ],
          ],
        ),
      ),
    );
  }
}
