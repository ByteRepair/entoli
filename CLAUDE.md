# agent-chat

Flutter (Linux/Web/Android) ChatGPT-style UI. Client-side; servers only broker
LLM connections. Each chat owns a persistent workspace directory.

## Architecture

Two backends, both reachable through `AgentBackend`:

- **OpenCode**: a native `opencode serve` process per chat, over HTTP + SSE.
  Desktop only — there is no binary to spawn on a phone or in a browser.
- **The built-in harness**: mini-swe-agent's loop, ported to Dart and running
  in this process. No server, no Python, nothing to install.

Desktop offers both and routes per chat (`RoutingBackend`); Android and the web
have only the harness. `state.json` records which one a chat was created with,
so changing the default leaves existing chats where they are.

- `conv.json` is the source of truth. `ChatController` accumulates a turn's
  events into it as they arrive; `ChatRepository` resolves which model runs and
  owns rewinding. Context is re-injected only when a turn is resent (see
  "Resending a message") — otherwise the agent's own session carries it.
- The backends run **on top of** agent-chat, not the other way around. Commands
  and agents are agent-chat's, and a backend is configured to take them; a
  backend's own global configuration is deliberately kept out.

### On-disk layout

`<dataDir>/chats/<chat-id>/` with `state.json`, `conv.json`, `resources/`, `workspace/`.
`<dataDir>/commands/*.md` and `<dataDir>/agents/*.md` are the user's own
prompt files, beside `settings.json` — which holds the app-level model default,
`defaultBackend`, `approveCommands`, `opencodeEnv`, and `llmProviders`.
Data dir: `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` (desktop),
app-private storage (Android), OPFS (Web).

`<cacheDir>` is `~/.cache/agent-chat`, and holds only what a backend can be
told to rebuild — see "Commands and agents". Nothing the user typed lives
there, so it is safe to delete.

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

### The built-in harness

`MinisweAgent` is mini-swe-agent's control flow in Dart: render the system and
task prompts, ask the model, run the one command it asked for, show it the
result, repeat. It exits when a command's first line is
`COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` and it succeeded — upstream's marker,
kept verbatim so a model that has seen the original recognises it.

Ported rather than embedded because none of the ways of running the real Python
meet "no external setup": `flutter_python_bridge` shells out to the system
`python3` on desktop, Chaquopy is Android-only, Pyodide is web-only, and
litellm — which is how upstream reaches a provider at all — has native
dependencies that none of them can build. The loop is about a hundred lines of
actual logic, so the port is the small half of the work; the model clients are
the large half.

The prompts live in `templates.dart`, adapted from upstream's `mini.yaml` for a
conversation: upstream runs one task and exits, this is asked something else
once the turn is over. A turn's prose streams into the bubble as `TextDelta`,
its commands become tool labels, and the submission's body — everything after
the marker line — is appended as text when a model puts one there.

Two things the prompt has to say explicitly, both learned from watching a real
model fail: that a command only runs when the `bash` tool is called (a model
shown a fenced ```` ```echo MARKER``` ```` will imitate the fence and write the
line as prose, which does nothing), and that it should finish the moment it has
the answer (otherwise it keeps running `pwd`, `date`, `whoami` until the step
limit).

Every tool call gets an answer, including the ones never run — after a submit,
after an abort, for a tool that does not exist. A provider that sees a
`tool_use` with no matching result rejects the *next* turn, so padding them with
"this command was not executed" is what keeps the session usable.

`MinisweSession` holds the conversation as the model sees it, per chat, for as
long as the app runs. `resetSession` seeds a fresh one with a transcript, the
same way the opencode backend does.

#### Reaching a provider

`LlmClient` has two implementations: `OpenAiClient` (`/chat/completions` — and
so also OpenRouter, Groq, Ollama Cloud, ollama, LM Studio, vLLM) and
`AnthropicClient` (`/messages`). Anthropic is not reachable through the first
one: its system prompt is a parameter rather than a message, tool results ride
inside user turns, and consecutive results have to be folded into one turn
because a turn holding N `tool_use` blocks must be answered by exactly one turn
holding all N results.

Thinking is handed back with the `signature` it arrived with. With thinking
enabled, Anthropic rejects a tool-use turn whose thinking was dropped, so
`LlmMessage` carries `reasoningSignature` for no other reason. Enabling
thinking also pins the temperature at 1, so the two are never sent together.

Providers are configured in `settings.json` under `llmProviders` — id, API
shape, base URL, key, and an optional model list — and `llmProviderPresets`
fills in the endpoints worth naming so that adding one is a key rather than a
URL nobody remembers. A key can be left out and named as `apiKeyEnv` instead,
which is how one already exported stays out of the file. `LlmRegistry` builds a
client per provider and rebuilds it when the URL or key changes; a provider
that lists no models is asked, and one that cannot answer contributes nothing
rather than failing the whole list.

#### Errors, and how long the UI waits

Failures are reported as they happen: a rejected key or a bad request reaches
`ErrorEvent` on the first attempt, and a retryable one (429, 5xx, a connection
that never opened) emits `RetryEvent` the instant it fails. Four attempts with
1s/2s/4s backoff means a persistent rate limit is reported after ~7s of
waiting — against opencode's measured ~78s, which it spends retrying silently.

That difference is why `stallTimeout` is on `AgentBackend` rather than being one
app-wide constant. Only the backend knows what silence means: opencode's 45s is
a workaround for failures it hides, while the harness reports everything and so
needs a budget longer than the longest command it would allow
(`commandTimeout + 60s`). Sharing one number would have killed a legitimate
60s build at 45s. `turnStallTimeoutProvider` now only overrides it, for tests.

#### Running the commands

`Shell` is the platform-varying part: `LocalShell` on desktop and Android,
`UnavailableShell` in a browser.

`Shell.canRunCommands` is what a browser actually changes, and it is not one
failing command — it is the whole loop. Submitting is itself a command, so with
no shell a turn could never finish: the agent would nudge the model three times
and end on a red error. False therefore drops `bashTool` from the request, uses
a system prompt with no submission protocol in it, and treats a reply with no
tool call as the finished answer rather than a format error.

`LocalShell` prepends `exec 2>&1` to the script rather than merging two Dart
streams — a compiler's errors interleaved with its progress is the whole value
of reading them, and separate pipes arrive in whatever order they flush. It
spawns under `setsid` where that exists so a timeout can kill the process
group: a timed-out `npm install` that only loses its shell keeps downloading.
Whether `setsid` is there is learned by trying it, not by probing first.

Approvals are the chat's `approveCommands` setting (`meta.json` over
`settings.json`), resolved once in `ChatRepository` and arriving with the
prompt — so it is a `MinisweAgent` parameter beside `approve`, not part of
`MinisweOptions`, which holds only what is genuinely per-agent.
`AgentBackend.honoursApprovals(chatId)` says whether it means anything at all,
and the chat settings page hides the field where it does not: opencode has
permission rules of its own, and a control that silently does nothing is worse
than no control.

The `ApprovalRequestEvent` is emitted *before* the agent waits on it, because
the banner is where the answer comes from. The completer is therefore created
when the event is forwarded, not when it is awaited, and an answer completes it
in place rather than removing it — a user who clicks faster than the loop asks
would otherwise leave it waiting on a completer nobody holds. A turn that ends
with one outstanding denies it, and `ChatController` stops its stall clock while
one is on screen — nobody answers a banner in 45 seconds flat.

`test/live/miniswe_live.dart` drives a real provider through the production
path. It deliberately does **not** call
`TestWidgetsFlutterBinding.ensureInitialized()`: that installs an
`HttpOverrides` answering every request with a 400, which is the whole of what a
live test is for. That rules out `rootBundle`, so it copies `assets/prompts/`
off disk instead of using `BundledPrompts`.

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
while the block is still being written — which is also how the UI knows to say
"Thinking…", and how the controller finds the block a delta or a close belongs
to. It searches for that open block rather than assuming it is the last part:
a provider that interleaves parts can start a tool between a block's deltas
and the event closing it, and assuming the last part wrote the thinking twice. A block that was never timed — an older conversation, an aborted
turn — is still worth opening, so it reads "View thinking".

`ReasoningPart` is not a `TextPart`, so `plainText` leaves it out: a rewound
session is seeded with what was said, never with what was thought.

A tool call and the result answering it are one label. The parts stay separate
in `conv.json` (they arrive at different times) and the UI pairs them by
`callID`; a result whose call is gone draws its own.

### Commands and agents

agent-chat owns these, not the backend. `PromptLibrary` is the whole of what
the composer's `/` and `@` menus offer, and it is built once at startup from
two `PromptSource`s in precedence order: the presets packaged under
`assets/prompts/{commands,agents}/`, then `$AGENT_CHAT_CONFIG/{commands,agents}/`.
A file the user wrote replaces the preset it shares a name with. Entries come
back sorted by name, so the menu does not reorder when a source does.

A prompt file is opencode-shaped: YAML frontmatter, then the template a command
expands to or the system prompt an agent runs under. `PromptDocument` reads
only the top-level scalars out of the frontmatter — `description` is all the
menu needs — and keeps the file verbatim in `source` for whoever parses YAML
properly. That is what gets written back out to a backend.

`completions` is therefore **not** on `AgentBackend`: the list is the same
whichever backend runs the chat, so `completionsProvider` reads the library
directly and is synchronous. Opening the menu no longer starts a server.

The library is built once, in `main`, and never reloaded. A file added to
`$AGENT_CHAT_CONFIG` while the app is running does not appear until a restart —
deliberately, because half of it could not take effect anyway: a server already
spawned has read its config directory and will not read it again.

#### Handing the library to opencode

opencode discovers commands and agents by globbing `{command,commands}/**/*.md`
and `{agent,agents}/**/*.md` under every config directory it knows. Its global
one is `$XDG_CONFIG_HOME/opencode` and is **always** in that list;
`OPENCODE_CONFIG_DIR` only *appends* a directory, so it cannot isolate anything
on its own (both verified against opencode 1.18.18: `Global.Path.config`,
`ConfigPaths.directories`).

So `opencodeEnvironment` starts every server with `XDG_CONFIG_HOME` pointed at
`<cacheDir>`, which makes opencode's config dir `~/.cache/agent-chat/opencode`,
and `writeOpencodeConfig` lays the library down there as `command/*.md` and
`agent/*.md`. Rewritten from scratch on every start: a deleted command has to
stop being offered. The user's `~/.config/opencode` stops applying — that is
the point — but opencode's own built-ins (`init`, `review`, `build`, `explore`,
`general`, `plan`) remain, since they are compiled in rather than read off disk.

`XDG_DATA_HOME` is deliberately left alone: credentials and the session
database live there and are the user's, not ours. The trade-off of moving
`XDG_CONFIG_HOME` is that tools opencode spawns inherit it — `gh` in
particular reads `$XDG_CONFIG_HOME/gh`. The environment editor in settings is
the way out (`GH_CONFIG_DIR=...`), and it is why the user's variables are
applied *under* ours rather than over them.

`commandPattern` and `mentionPattern` live in `lib/domain/models.dart` beside
`CompletionKind`, and both backends dispatch on them: the composer offers one
menu, so loosening the syntax for one runtime and not the other would silently
send a command to the model as prose. `transcriptOf` is shared for the same
reason — a rewound chat should read the same whichever backend ran it, and only
the preamble is each backend's own.

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
path and prints timestamped events, and prints what `GET /command` and
`GET /agent` really return under the isolated config dir. It is not a
`_test.dart` file, so `flutter test` skips it; run it by name when the question
is what opencode actually emits.

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

`approveCommands` follows the same three levels and is the one the harness
actually reads per turn; opencode has its own permission rules and ignores it.
`defaultBackend` deliberately does not: it decides what a *new* chat gets, and
an existing one keeps what `state.json` says.

`settings.json`'s `opencodeEnv` is the environment every server is spawned
with, and that the harness runs its commands under — API keys, and whatever
else a provider or a CLI reads out of one. It is read off disk when used rather
than captured at startup, so an edit applies to the next server a chat starts
and to the next command the harness runs; a server already running keeps what
it was spawned with, and the settings page says so.

The settings page is four sections in this order: **New chats** (default
backend, default model), **Built-in harness** (ask-before-running, providers),
**Environment**, and deleting everything. Environment is its own section rather
than opencode's because both backends read it.

### Shared UI

`lib/ui/widgets/` holds what more than one page needs: `ModelPicker` (the
selector plus its loading and failure states) over `ProviderModelSelector`
(which owns every rule about the pair, and is tested directly in
`provider_model_selector_test.dart` rather than through both pages), the
`Default`-plus-reset pairing and `InheritableDropdown` over it (the labelled
field whose first entry stores null and names what null resolves to — the
backend, approval and reasoning-effort fields are all one call to it),
`backendLabel`, the `promptForText` / `promptForPair` / `confirm`
dialogs, and `AttachmentChip` / `AttachmentStrip`.
Tests share `test/harness.dart` (`TestApp`, `tempConfig`, `pumpUntil`, the
dropdown finders) and `test/fakes.dart` (`FakeBackend`, whose `scriptedEvents`
and `hold` drive a turn, plus `FakeAttachmentPicker` and `testLibrary`).

Streamed deltas are coalesced into one state update per frame: per-token
updates made the reply's text quadratic and rebuilt every visible bubble
thousands of times per turn. One buffer carries both kinds of delta, so
switching between thinking and reply flushes what it held — otherwise the two
would fold into each other's part.

`activity_label.dart` owns the labels and the drawer behind them; the bubble
walks the parts and decides which of the two each one is.

`Composer` opens a menu above the field when the caret sits in a `/` or `@`
token, over a library that is already loaded — so it takes no chat id, has no
loading state, and starts nothing.
Enter, Tab and the arrows are bound only while the menu has a match — the rest
of the time they have to keep doing what they do in a text box. The `+` button
left of the field is a second way in: for a command or an agent it types the
trigger character rather than opening its own list, so both routes share one
code path; for a file it opens the chooser.

### AgentBackend abstraction

`lib/domain/agent_backend.dart` — platform-agnostic interface. Implementations:
`OpencodeBackend`, `MinisweBackend`, and `RoutingBackend` over both. Which ones
exist is decided by the conditional import in `lib/core/platform/backend.dart`;
`availableBackendKinds()` in `default_backend.dart` is the same fact for the
UI, so settings never offers opencode where there is no binary to spawn.

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

No Python is embedded anywhere: mini-swe-agent's loop is ported to Dart. See
"The built-in harness" for why, and `assets/python/` is left empty because of
it.