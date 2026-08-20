# The sidebar's list

Chats sit under a heading — Today, Yesterday, Previous 7 days, Previous 30 days,
then the month, with the year on it where that is not this one. Each row was a
title over its own timestamp, which is a date the reader has to compare against
eleven others to place; the heading places all of them at once, and the row is
the title and nothing else.

`groupChatsByDate` is the whole of it, in `chat_groups.dart` and away from the
widget so the boundaries can be tested at a date of the test's choosing —
`now` is a parameter for that reason. It takes the headings in the order the
chats come in rather than ranking them, which is sound because the list is
sorted newest first: from there a chat can only ever land in the group it is
already in or one further down. Days are counted on a UTC calendar, since a
local day either side of a clock change is 23 or 25 hours and yesterday would
round to today.

**Search reads the titles and nothing else.** Searching what was *said* means
reading every `conv.jsonl` off disk on every keystroke; the titles are already
in memory, being what the list draws. What is matched is the title as shown, so
a chat the title model never named is found under `(untitled)`. The field is
there whenever the project has chats in it — it goes with them, not with the
results, or a search that matched nothing would take away the only way to undo
itself.

The query is a `ValueNotifier` the list listens to rather than `setState` on the
sidebar: a keystroke changes the list, and the project switcher above it has no
business rebuilding to answer one. It holds the *text* rather than the field's
`TextEditingController`, which is a `ValueListenable` and would have done — its
value is the text and the caret together, so moving the caret in the search box
would regroup the whole list for nothing. Same reason `Composer` keeps
`_canSend`.

Switching projects clears it, for the reason switching clears the selected chat:
the list the query was written against has just been replaced, and kept it would
answer a project the user has only just arrived in with "nothing matches".

## Pinned chats

A chat can be pinned from its sidebar context menu. Pinned chats sit under a
"Pinned" heading ahead of every date group, newest first among themselves, and
a single pinned chat still gets the heading — the pin is a fact the user set,
not a date the reader has to place. `groupChatsByDate` partitions on
`ChatState.pinned` before it groups by date, so the pinned group is always
drawn first and the date groups follow in the order they were already in.

`pinned` lives on `ChatState` rather than `ChatMeta` for the same reason
`tempTtlExpiresAt` does: the sidebar list holds `ChatState`s and reads the
flag off them without loading `meta.json` per chat per refresh. Pinning is not
a setting override — it is a state of the chat, like the TTL anchor — so it
belongs beside it.

**A pinned chat cannot be temporary.** `ChatRepository.pinChat` clears the
TTL anchor and sets the chat's `meta.tempChatTtl` override to `off` in the same
write, the way `keepExpiredChat` does — so `saveState`'s TTL resolution keeps
the chat non-temporary even if the app or project default later widens. The
chat settings page replaces the TTL combobox with "This chat is pinned and
cannot be temporary" while `state.pinned` is set, so the user is told rather
than left to find the field gone. The chat page title bar shows a pin in the
slot the hourglass countdown takes on a temporary chat; the two are mutually
exclusive, since pinning clears the expiry.

Unpinning clears `pinned` and leaves the TTL override at `off`, so the chat
stays non-temporary and the combobox returns with `Off` selected — the user
can re-enable temporary from there. Restoring the prior TTL state across a
pin/unpin was rejected: it is more state to track for a case nobody asked for,
and `off` is the honest answer for a chat that was just unpinned.
