import "package:flutter/material.dart";

import "../chat/widgets/markdown_text.dart";
import "completion_field.dart";
import "discard_guard.dart";
import "resettable_field.dart";
import "page_bar.dart";

/// Prose the model reads — a trigger's prompt, an agent's system prompt, a
/// set of instructions — shown as the chat will render it, over the button
/// that opens [PromptPage] to change it. Formatted rather than raw: it is
/// markdown everywhere it is read, so a list in it is checked here. Written
/// once and read many times afterwards, so the page it sits on shows it, and
/// one long enough to need the room gets a whole page to grow in rather than
/// a box a few lines tall.
class PromptField extends StatelessWidget {
  const PromptField({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.project,
    this.completions = true,
    this.editable = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  final String label;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;

  /// See [PromptPage.project] and [PromptPage.completions].
  final String? project;
  final bool completions;

  final bool editable;
  final EdgeInsets padding;

  /// Tall enough to read what it says, short enough that a long system
  /// prompt does not push the rest of its page out of sight.
  static const _previewHeight = 320.0;

  Future<void> _edit(BuildContext context) async {
    final edited = await PromptPage.open(
      context,
      title: label,
      text: value,
      hint: hint,
      project: project,
      completions: completions,
    );
    if (edited != null) onChanged(edited);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LabelledField(
      label: label,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: editable ? () => _edit(context) : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: _previewHeight),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              // Clipped rather than overflowing: the whole of it is a tap
              // away, and this is only the look of it.
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: value.trim().isEmpty
                    ? Text(
                        hint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : MarkdownText(value),
              ),
            ),
          ),
          if (editable) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _edit(context),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text("Edit ${label.toLowerCase()}"),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// [PromptField]'s text on a page of its own: the box is the page. Where
/// [completions] holds it is the composer's own field, so `/skills` and
/// `@agents` complete here the way they do in a chat — a trigger's prompt
/// and an agent's are dispatched through the same library, and being offered
/// them anywhere else and not here was the tell. Instructions are not: an
/// `@` there is a file to pull in, and offering agents would mislead.
///
/// Pops the new text, or nothing where it was discarded.
class PromptPage extends StatefulWidget {
  const PromptPage({
    super.key,
    required this.title,
    required this.text,
    required this.hint,
    this.project,
    this.device,
    this.completions = true,
    this.confirmLabel = "Save",
  });

  final String title;
  final String text;
  final String hint;

  /// What leaving with the text is called: Save where it is written back,
  /// Send where it goes on to the model at once (a message edited).
  final String confirmLabel;

  /// The project whose library the `/` and `@` menus offer, so the text is
  /// composed against the set it will be read with. Null is the default
  /// project, the way it is everywhere a project is named.
  final String? project;

  /// The paired device whose project [project] is, where it is not this
  /// one's — a mirrored chat's message is composed against its home's
  /// library, the way its composer is.
  final String? device;

  final bool completions;

  /// Pushes the page and answers what it popped.
  static Future<String?> open(
    BuildContext context, {
    required String title,
    required String text,
    required String hint,
    String? project,
    String? device,
    bool completions = true,
    String confirmLabel = "Save",
  }) => Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => PromptPage(
        title: title,
        text: text,
        hint: hint,
        project: project,
        device: device,
        completions: completions,
        confirmLabel: confirmLabel,
      ),
    ),
  );

  @override
  State<PromptPage> createState() => _PromptPageState();
}

class _PromptPageState extends State<PromptPage> {
  final GlobalKey<CompletionFieldState> _field = GlobalKey();
  late final TextEditingController _controller = TextEditingController(
    text: widget.text,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _edited => _controller.text != widget.text;

  @override
  Widget build(BuildContext context) {
    final decoration = InputDecoration(
      hintText: widget.hint,
      alignLabelWithHint: true,
      border: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    return DiscardGuard(
      edited: () => _edited,
      child: Scaffold(
        appBar: PageBar(
          title: Text(widget.title),
          leading: const DiscardButton(),
          actions: [
            if (widget.completions)
              PopupMenuButton<VoidCallback>(
                icon: const Icon(Icons.add),
                tooltip: "Insert",
                onSelected: (action) => action(),
                itemBuilder: (context) =>
                    completionInsertItems(context, _field),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              child: Text(widget.confirmLabel),
            ),
          ],
        ),
        body: SafeArea(
          child: widget.completions
              ? CompletionField(
                  key: _field,
                  controller: _controller,
                  project: widget.project,
                  device: widget.device,
                  expands: true,
                  maxLines: null,
                  autofocus: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: decoration,
                  // The box is the page, so the menu goes under it — where
                  // the composer's is, which is against the edge the field
                  // is on.
                  layout: (menu, field) => Column(
                    children: [
                      Expanded(child: field),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: menu,
                      ),
                    ],
                  ),
                )
              : TextField(
                  controller: _controller,
                  expands: true,
                  maxLines: null,
                  autofocus: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: decoration,
                ),
        ),
      ),
    );
  }
}
