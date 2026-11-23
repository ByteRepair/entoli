/// What the app says to the agent in the conversation, rather than the user:
/// a background job's end that woke it, a plan with tasks left. Wrapped in a
/// `<system-notification>` tag, like Claude Code's task notifications, so the
/// model reads it as the app speaking and the chat draws it as a note. Read
/// off the text, the way `shellBypassCommand` and `wiredSkillFromText` are,
/// so a reload and a resend answer the same.
library;

const _tag = "system-notification";

/// [lines] as one notification.
String systemNotification(Iterable<String> lines) =>
    ["<$_tag>", ...lines, "</$_tag>"].join("\n");

/// Whether [text] is a notification the app said rather than anything the
/// user typed.
bool isSystemNotification(String text) => text.trimLeft().startsWith("<$_tag>");
