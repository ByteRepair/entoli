# agent-chat

Flutter (Linux/Web/Android) ChatGPT-style UI. Client-side; servers only broker
LLM connections. Each chat owns a persistent workspace directory.

## Architecture

- **Linux desktop**: OpenCode (native `opencode serve` process) over HTTP + SSE.
- **Web / Android**: mini-swe-agent (pure Python) under Pyodide / Chaquopy.
- `conv.json` is the source of truth; the agent is a stateless inference engine.
  Before each turn we re-inject context; the agent's internal session is ephemeral.

### On-disk layout

`<dataDir>/chats/<chat-id>/` with `state.json`, `conv.json`, `resources/`, `workspace/`.
Data dir: `~/.config/agent-chat` (desktop), app-private storage (Android), OPFS (Web).

### OpenCode server model

One `opencode serve` per chat, started lazily on first message with the
chat's workspace as the process working directory. `POST /session` creates
a dir-bound session (inherits server cwd). All messages use
`POST /session/:id/prompt_async` (fire-and-forget, returns 204). Events
stream via SSE `/event`: `message.part.delta` (text), `message.part.updated`
(tool status changes), `session.idle` (turn done). Server stops when
switching chats or disposing.

SSE only emits events for sessions created via `POST /session` on that
server — `opencode run --dir` sessions do NOT get SSE events (verified
2026-08-15, opencode 1.18.18). `opencode run --format json` stdout only
emits `step_start` + `tool_use` events; text deltas are missing. This is
why we use `POST /session` + `prompt_async` instead of `opencode run`.

`prompt_async` types `model` as `{providerID, modelID}` and sets
`additionalProperties: false`, so a bare model string makes the server reject
the whole request. Provider and model therefore travel together the whole way
down; when only one is known we send neither and let the server choose.

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

`OpencodeTransport` abstracts the server lifecycle and HTTP/SSE so tests
can inject a fake. Real impl: `RealOpencodeTransport`. Test fake:
`FakeOpencodeTransport` in `opencode_backend_test.dart`.

### Resending a message

Edit and regenerate discard the turn and everything after it, then re-run it.
The live opencode session still holds the discarded exchange, so
`resetSession` deletes it and hands the next `sendPrompt` a transcript of the
kept messages to inject (`noReply`) into the fresh session. This is the one
place where the "conv.json is the source of truth, re-inject context" rule is
actually exercised.

### Setting overrides

A chat's `meta.json` overrides the app default, which overrides the backend's
own. Each level stores `null` to mean "inherit", shown in the UI as the
`Default` option — always first in its list, with a reset button beside the
field. Pinning a model pins its provider too: the two are only ever sent as a
matched pair.

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