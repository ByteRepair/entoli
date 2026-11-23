/// A first message can be a whole file pasted in, and the title model is
/// charged for every token of it.
const _promptLimit = 2000;

const _maxWords = 20;

/// Long enough for twenty words, short enough that one long one cannot push
/// the sidebar around.
const _maxChars = 120;

/// What the title model is asked. One message, and the answer names the chat.
String titlePrompt(String message) =>
    """
Name this conversation from the user's first message, in at most $_maxWords words.

Reply with the title alone: no quotes, no trailing punctuation, no explanation,
and nothing about having been asked for a title.

The message:

${message.length > _promptLimit ? message.substring(0, _promptLimit) : message}""";

/// The title as it can be shown. Every rule here is one of the instructions
/// above being ignored, which models do — and the reply names the chat
/// verbatim, so none of it is taken on trust.
String? cleanTitle(String raw) {
  var title = raw
      .trim()
      .split("\n")
      .first
      // Repeated, so a heading marker and a "Title:" prefix come off in
      // either order.
      .replaceFirst(
        RegExp(r"""^(?:["“”'*#\s]+|title\s*:\s*)+""", caseSensitive: false),
        "",
      )
      .replaceFirst(RegExp(r"""["“”'*.,\s]+$"""), "")
      .replaceAll(RegExp(r"\s+"), " ");
  final words = title.split(" ");
  if (words.length > _maxWords) title = words.take(_maxWords).join(" ");
  if (title.length > _maxChars) {
    title = "${title.substring(0, _maxChars).trimRight()}…";
  }
  return title.isEmpty ? null : title;
}
