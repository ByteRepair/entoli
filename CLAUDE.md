# agent-chat

Flutter (Linux/Web/Android) ChatGPT-style UI. Client-side; servers only broker
LLM connections. Each chat owns a persistent workspace directory.

## Architecture

- **Linux desktop**: OpenCode (native `opencode serve` process) over HTTP + SSE.
- **Web / Android**: mini-swe-agent (pure Python) under Pyodide / Chaquopy.
- `conv.json` is the source of truth. `ChatController` accumulates a turn's
  events into it as they arrive; `ChatRepository` resolves which model runs and
  owns rewinding. Context is re-injected only when a turn is resent (see
  "Resending a message") — otherwise the agent's own session carries it.

### On-disk layout

`<dataDir>/chats/<chat-id>/` with `state.json`, `conv.json`, `resources/`, `workspace/`.
Data dir: `~/.config/agent-chat` (desktop), app-private storage (Android), OPFS (Web).

### OpenCode server model

One `opencode serve` per chat, started lazily on first message with the
chat's workspace as the process working directory. `POST /session` creates
a dir-bound session (inherits server cwd). All messages use
`POST /session/:id/prompt_async` (fire-and-forget, returns 204). Events
stream via SSE `/event`: `message.part.delta` (text), `message.part.updated`
(tool status changes), `session.idle` (turn done). A server outlives a chat
switch — a turn keeps running while you read another chat — and is stopped by
deleting the chat or exiting the app.

SSE only emits events for sessions created via `POST /session` on that
server — `opencode run --dir` sessions do NOT get SSE events (verified
2026-08-15, opencode 1.18.18). `opencode run --format json` stdout only
emits `step_start` + `tool_use` events; text deltas are missing. This is
why we use `POST /session` + `prompt_async` instead of `opencode run`.

`prompt_async` types `model` as `{providerID, modelID}` and sets
`additionalProperties: false`, so a bare model string makes the server reject
the whole request. Provider and model therefore travel together the whole way
down; when only one is known we send neither and let the server choose.

### Thinking and tool runs

A turn is not just a reply: the model thinks, runs tools, thinks again. Each of
those is a part of the assistant message and the chat draws it as a frameless
label above the bubble, in the order it happened, with the detail behind a
bottom drawer. The bubble holds only what the model said.

Thinking streams as `message.part.delta` on a part opencode announced as
`{type: "reasoning", time: {start}}`; the same part is announced again with
`time.end` and the whole text once the block closes. Nothing on the delta says
which kind of part it belongs to, so `OpencodeBackend` tracks the open
reasoning part IDs per chat and routes deltas to `ReasoningDelta` or
`TextDelta` accordingly — without that, thinking lands in the reply as text
(verified 2026-08-15, opencode 1.18.18, against nemotron-3-ultra). The closing
`ReasoningEnd` carries the whole text as well as the duration, so a provider
that streams no deltas at all still fills the block.

`durationMs` is what the label reads ("Thought for 12 seconds") and is null
while the block is still being written, which is also how the UI knows to say
"Thinking…". A block that was never timed — an older conversation, an aborted
turn — is still worth opening, so it reads "View thinking".

`ReasoningPart` is not a `TextPart`, so `plainText` leaves it out: a rewound
session is seeded with what was said, never with what was thought.

A tool call and the result answering it are one label. The parts stay separate
in `conv.json` (they arrive at different times) and the UI pairs them by
`callID`; a result whose call is gone draws its own.

### Commands and agents

`CompletionKind` names the two of them and carries the trigger character, so
one `completions(chatId, kind)` runs the whole chain — backend, transport,
client, provider — rather than a parallel pair per layer. `GET /command` and
`GET /agent` list what the workspace offers; both come from the chat's own
server, so asking for them starts it if the chat has not sent anything yet.
Entries with `hidden: true` are opencode's own machinery (compaction, titling)
and are filtered out.

The syntax is parsed in `OpencodeBackend`, not in the repository or the UI:
`/` and `@` are opencode's, and `conv.json` stores the message as typed, so a
regenerated turn re-parses to the same thing. The dispatch patterns are looser
than the names opencode actually uses — a command name is any run without a
slash — because anything the composer's menu can offer has to dispatch.

A message that is nothing but `/name` plus arguments runs
`POST /session/:id/command` instead of `prompt_async`. That endpoint types
`model` as one `"provider/model"` string — not `prompt_async`'s pair — and its
response only arrives once the turn is over, so it is awaited last, after the
event stream is attached. Everything else about the turn is identical: the
same SSE events, in the same order (verified 2026-08-15, opencode 1.18.18).

`@name` mentions ride along as `{"type": "agent", "name": ...}` parts ahead of
the text part. The server accepts any name without checking it — an unknown
agent is a 204 like any other.

`session.error` carries `{name, data.message}` (APIError adds `statusCode`)
and ends the turn — we turn it into an `ErrorEvent`, which the chat renders as
red text in place of the reply. `MessageAbortedError` is our own abort, not a
failure, so it is dropped.

A retryable failure (HTTP 429 and friends) does not reach `session.error` for
a long time: opencode retries internally with growing backoff and only reports
the error once it gives up — measured at ~78s over five attempts against a
rate-limited ollama-cloud account. Each attempt is announced immediately on
`session.status` as `{type: "retry", attempt, message, next}`, so that is what
we surface as a `RetryEvent` (first one lands ~2s in). It is turn-scoped view
state, never a message part, so it is not persisted.

`test/live/opencode_live.dart` drives a real server through the production
path and prints timestamped events. It is not a `_test.dart` file, so
`flutter test` skips it; run it by name when the question is what opencode
actually emits.

`transport.subscribe` is awaited before prompting and returns only once
`/event` is attached — opencode never replays, so an event emitted before the
stream is open is gone. Each subscription also captures its own turn's
controller, so a straggling event from the previous turn cannot close the new
one.

`OpencodeTransport` abstracts the server lifecycle and HTTP/SSE so tests
can inject a fake. Real impl: `RealOpencodeTransport`. Test fake:
`FakeOpencodeTransport` in `opencode_backend_test.dart`.

Servers are per chat and live until the app exits, when `AgentBackend.shutdown`
(wired to `AppLifecycleListener.onExitRequested` in `main.dart`) stops them.
They are not our process's children in any way the OS cleans up, so without
that they outlive the app. `RealOpencodeTransport` therefore keys its map on
the spawn in flight rather than the server it produces: opening the composer's
menu and sending a message both call `ensureServer`, and the loser of that
race would never reach the map to be stopped.

Every write endpoint in `OpencodeClient` checks its status code. A rejected
prompt is otherwise indistinguishable from a stall: no events ever arrive and
the turn dies on the timeout with nothing to show.

### Resending a message

Edit and regenerate discard the turn and everything after it, then re-run it.
The live opencode session still holds the discarded exchange, so
`resetSession` deletes it and hands the next `sendPrompt` a transcript of the
kept messages to inject (`noReply`) into the fresh session. This is the one
place where the "conv.json is the source of truth, re-inject context" rule is
actually exercised.

### Attachments

The `+` button offers Image and File. Both open the same chooser and differ
only in its filter, so they share one path: `AttachmentPicker` (a domain
interface, `file_selector` behind it, faked in tests) hands back `Attachment`s
of filename, mime type and bytes.

Bytes are saved under the chat's `resources/` and the message keeps a
`FilePart` naming the resource. That is what makes an edit or a regenerate
work: the parts are in `conv.json`, so a resend reads the bytes back off disk
rather than needing the composer to still hold them. `saveAttachments` leaves
one that already has a resource where it is, so replaying a turn does not copy
its bytes again.

The store's resource I/O is async where the rest of it is sync: a JSON file is
small enough to write on the UI thread, an attachment is not. A widget test's
clock is fake and never advances real I/O, which is what `pumpUntil` in
`test/harness.dart` is for.

opencode takes the bytes as a data URL in a `{type, mime, filename, url}` file
part. `file:` is the other scheme it reads, but it only works where the server
shares our filesystem, which rules out web and Android. It inlines a
`text/plain` attachment into the prompt and hands the model anything else as a
blob, which is why the picker prefers `text/plain` over
`application/octet-stream` for a file nothing can name a type for.
`POST /session/:id/command` takes files in `parts` as well — there the command
itself is the text.

A rewound session's transcript names the files the kept messages carried
instead of resending them: only the turn being replayed carries its own back.

### Setting overrides

A chat's `meta.json` overrides the app default, which overrides the backend's
own. Each level stores `null` to mean "inherit", shown in the UI as the
`Default` option — always first in its list, with a reset button beside the
field. Pinning a model pins its provider too: the two are only ever sent as a
matched pair.

`Default` is a live reference, not a snapshot: a chat that pins nothing uses
whatever the global default currently is, and retargeting the global retargets
every such chat. With nothing to inherit, the model list stays empty rather
than falling back to a provider — a guessed default would mean something that
shifts as providers come and go.

Both settings pages render the same `ProviderModelSelector`; it owns those
rules, and each page only says where the values come from and where they go.
`meta.json`'s `temperature` and `reasoningEffort` are saved but not yet sent:
`prompt_async` has no field for them (verified against `GET /doc`, opencode
1.18.18), so they would need per-session config to take effect.

### Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` (the
selector plus its loading and failure states) over `ProviderModelSelector`
(which owns every rule about the pair, and is tested directly in
`provider_model_selector_test.dart` rather than through both pages), the
`Default`-plus-reset pairing, the `promptForText` / `confirm` dialogs, and
`AttachmentChip` / `AttachmentStrip`.
Tests share `test/harness.dart` (`TestApp`, `tempConfig`, `pumpUntil`, the
dropdown finders) and `test/fakes.dart` (`FakeBackend`, whose `scriptedEvents`
and `hold` drive a turn, plus `FakeAttachmentPicker`).

Streamed deltas are coalesced into one state update per frame: per-token
updates made the reply's text quadratic and rebuilt every visible bubble
thousands of times per turn. One buffer carries both kinds of delta, so
switching between thinking and reply flushes what it held — otherwise the two
would fold into each other's part.

`activity_label.dart` owns the labels and the drawer behind them; the bubble
walks the parts and decides which of the two each one is.

`Composer` opens a menu above the field when the caret sits in a `/` or `@`
token. `completionsProvider` is watched only while that menu is open, so a
chat that never uses one never starts a server for it.
Enter, Tab and the arrows are bound only while the menu has a match — the rest
of the time they have to keep doing what they do in a text box. The `+` button
left of the field is a second way in: for a command or an agent it types the
trigger character rather than opening its own list, so both routes share one
code path; for a file it opens the chooser.

### AgentBackend abstraction

`lib/domain/agent_backend.dart` — platform-agnostic interface. Implementations:
`OpencodeBackend` (desktop), `MinisweChaquopyBackend` (Android),
`MiniswePyodideBackend` (Web). Selected via conditional import in
`lib/core/platform/backend.dart`.

## Development

- Build/test Linux desktop inside the `flutter-dev` toolbox (host lacks
  cmake/ninja/clang++): `toolbox run --container flutter-dev flutter build linux --debug`.
- UI runs forwarded to host: `toolbox run --container flutter-dev flutter run -d linux --debug`.
- Codegen: `dart run build_runner build` (freezed + json_serializable).
- Analyze: `flutter analyze`. Tests: `flutter test`.

## Dependency note

Freezed 3.x requires `abstract class Foo with _$Foo` (not just `class`).
Build runner capped at `^2.15.1` to stay compatible with freezed 3.2.5's
analyzer constraint. riverpod_generator dropped due to analyzer conflict with
freezed; we use manual Riverpod providers.

### Pyodide / mini-swe-agent model

litellm is NOT available under Pyodide (native deps: fastuuid, tokenizers).
mini-swe-agent's `Model` is a `Protocol` — we provide a custom subclass that
calls OpenAI/Anthropic via `pyodide.http.pyfetch` (or the `openai` package,
which IS in Pyodide's package list). Same pattern for Chaquopy if needed.
Pyodide ships: pydantic 2.12.5, pydantic_core 2.41.5, openai 2.30.0, pyyaml,
jinja2, requests, rich, prompt_toolkit, platformdirs.