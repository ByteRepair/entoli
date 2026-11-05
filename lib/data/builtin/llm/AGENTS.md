# The model clients

## Reaching a provider

`LlmClient` has two wire implementations: `OpenAiClient` (`/chat/completions` — and
so also OpenRouter, Groq, Ollama Cloud, ollama, LM Studio, vLLM) and
`AnthropicClient` (`/messages`). Anthropic is not reachable through the first
one: its system prompt is a parameter rather than a message, tool results ride
inside user turns, and consecutive results have to be folded into one turn
because a turn holding N `tool_use` blocks must be answered by exactly one turn
holding all N results.

`OpenAiClient` has one flag that is not about the shape of the wire:
`returnProgress` asks for llama.cpp's `prompt_progress` frames, which arrive
while the prompt is still being read and become `LlmPromptProgress`. Off by
default and turned on only by `LlamaInstance`, because a hosted provider is
entitled to reject a body field it has never heard of and the strict ones do.
The frame arrives with `choices` empty, so it is read before the guard that
skips a frame with nothing in it — a detail worth knowing because moving that
read below the guard silently loses every one of them.

Thinking is handed back with the `signature` it arrived with. With thinking
enabled, Anthropic rejects a tool-use turn whose thinking was dropped, so
`LlmMessage` carries `reasoningSignature` and `ReasoningPart` carries
`signature` for no other reason — see "The projection". Enabling thinking also
pins the temperature at 1, so the two are never sent together.

Gemini's equivalent is on the tool call rather than the thinking (in
`GeminiClient`, an `OpenAiClient` subclass over its protected hooks): its OpenAI
shape puts `extra_content.google.thought_signature` on the first call of a
reply and answers 400 to a replay without it. `LlmToolCall.signature` and
`ToolCall.signature` carry it through the log for the same reason. A reply
with no signature at all — logged before they were kept, or made by another
model — goes to Gemini's host with LiteLLM's placeholder
`skip_thought_signature_validator` on its first call.

Its compat surface has no audio endpoints, so speech and transcription are
native `generateContent` calls in `GeminiClient` too — see "A provider's
models" in `lib/data/voice/AGENTS.md`.

Google retires a model for new accounts while its own list and models.dev
still name it, so nothing says in advance which are gone: a Gemini 404 reads
as "retired", and `GoogleProvider.retiredModels` is kept by hand.

Providers are configured in `settings.json` under `llmProviders` — id, API
shape, base URL, an optional model list — and that config is data only. **What
differs by who runs an endpoint is a class**: `LlmProvider`
(`providers/provider.dart`) and one subclass per provider, each holding its
preset, its terms, its image model, whether it takes PDFs, its retired models,
which client it speaks through, how a key is checked (`checkKey`) and which of
models.dev's models it offers (`models`). A wire format is a client — a
provider has one rather than being one, since half of them speak the same
protocol. `providerOf` reads a config as its class: by host, so an entry
renamed by hand keeps its server's quirks; then by models.dev id; then by wire
format alone (`OpenAiCompatibleProvider`, `AnthropicCompatibleProvider`), which
is what an endpoint typed in by hand is.

`checkKey` is a yes or no only where the provider said so: success, a spent
balance or a rate limit is a key it accepted, a 401 or 403 (Google's 400) one it
did not, and anything else throws rather than guess. Most ask the model list,
which they keep behind the key; OpenRouter's is public, so it asks `/key`, and
Z.ai and Ollama Cloud are not known to keep one, so they ask for a one-token
reply from the light default.

`llmProviderPresets` is the list of preset instances, so adding one is a key
rather than a URL nobody remembers. It and `providerOf`'s lookups are built
from one list of classes, `_kinds`, so a new provider is its class and one
entry there. A provider nothing guards — a local server, the on-device ones —
takes `KeyFree`, whose `needsKey` is what the dialog and the provider list
read.

**What a model can do is its type.** A provider `serve`s a model id as one
`Model` per thing it does (`lib/domain/model_capability.dart`): a
`ChatModel`, an `ImageModel`, a `TranscriptionModel`, a `SynthesisModel`.
`LlmProvider` serves chat alone; `OpenAiCompatibleProvider` adds the other
three over its client's image and audio endpoints, as the model's catalog
entry describes it, or all of them for an id the catalog does not describe.
`OnDeviceProvider` serves the downloaded text models and the installed voice
models, which the platform's `Voice` runs. A model holds what runs it, so the
provider says what exists and never runs anything. The backend, the voice
gates and the pickers resolve a pick to the kind they need (`resolve<T>`),
never asking the provider's or the client's type; no transcription model is
served where `ModelHost.cutsUtterances` is false. A key can be left out and
named as
`apiKeyEnv` instead, which is how one already exported stays out of the file.
`LlmRegistry` builds a client per provider and rebuilds it when the URL or key
changes; a provider that lists no models is asked, and one that cannot answer
contributes nothing rather than failing the whole list. The on-device server
and Apple's model are providers too, whose `client` is the pool or the channel —
which is how "may not be answering yet" arrives without the registry knowing
there is such a thing. See "Running a model on the device" in
`lib/data/local/AGENTS.md`.

**The key is resolved in one order, by `resolveKeyFor`**: the key stored for
the provider id in the secret store, then `apiKeyEnv` in the environment.
Only the named variable ever leaves `settings.json`; the stored one lives in
the secret store — see "Secrets at rest" in `lib/data/sync/AGENTS.md` — and
no `LlmProviderConfig` carries a key at all, so no write path has to strip
one. The resolved key is the client cache signature's third term, so an
edited stored key rebuilds the client the way an edited URL does.

**The client's TLS trust is the system's root store, with one fallback.** The
first handshake verifies against the OS's roots as the OS has them; where
that refusal is the certificate verification alone — a Windows machine whose
root store has never been refreshed past a root the provider now chains
under, the store a `dart:io` client never triggering the refresh schannel's
own lookups do (ollama.com's Google-signed chain is the case in point) — the
same request runs once more against the Mozilla set bundled as
`assets/certs/cacert.pem`, and that client is the endpoint's from then on.
Everything else a handshake could die of keeps its own error, and a chain
neither set trusts fails as it would have. See `lib/core/tls.dart`.

A `RateLimitGate` is built per turn in `BuiltinBackend.sendPrompt` and shared by
the parent `BuiltinAgent` and every sub-agent it spawns: it bounds in-flight
`LlmClient.stream` calls to `BuiltinOptions.maxConcurrentLlmRequests` (4
default) through a `GatedLlmClient` wrapper, and coordinates 429 backoff so a
75-vote fan-out doesn't each-retry-into the same rate limit. When any one
request gets a 429, the gate sets a shared cooldown that every other in-flight
or queued request honours; backoff grows exponentially across successive 429
episodes (1s → 2s → 4s → … → 60s cap) and resets on any successful request. The
gate is distinct from `maxConcurrentSubAgents` (8), which bounds long-lived
agent parallelism — one sub-agent makes up to `stepLimit` calls. Null for agents
built against a raw client (tests), where the per-agent retry path governs.

## How much of an allowance is spent

`LlmProvider.usage` answers it, as a list of `UsageWindow`s
(`lib/domain/provider_usage.dart`): a label in the provider's own period, what
is `used` of a `max`, the unit the two are counted in, and when it starts
again where the provider says. `used` is always what is gone — a provider
that reports what is left is converted where it is read — and a max rather
than a percentage, because what a provider counts is not always a share: a
dollar cap is a number of dollars. The default is nothing, which is what
most providers have to say; the Providers section in Settings draws a bar per
window under the row and nothing at all for an empty list.

**Only where the answer is the provider's to keep stable.** Three say it:

- **OpenRouter** — `/key`, documented: the key's spending cap, what is left of
  it and whether it resets daily, weekly or monthly. Its periods are UTC's, so
  the reset is computed; a key with no cap has nothing to show.
- **Groq** — no endpoint, but every reply carries documented
  `x-ratelimit-*` headers. `OpenAiClient.responded` hands a reply's headers to
  a subclass, `GroqClient` keeps the requests-per-day pair from the last one,
  and the provider reads it off the client — which is why `usage` is handed
  the client turns run over, the registry's cached one under the turn's
  wrappers. Nothing until a reply has arrived; the tokens pair is per minute,
  a pace rather than an allowance, and is left out.
- **Ollama Cloud** — the exception to the rule, kept because it was asked
  for: `ollama.com/api/usage` is what Ollama's own settings page reads and is
  not documented. It has answered with `limits.session` and `limits.weekly`
  as fractions, and since October 2026 with request counts and no `limits`,
  which reads as nothing rather than a failure.

Z.ai's coding-plan quota, Claude CLI's `rate_limit_event` and Codex's
`account/rateLimits/read` exist and are left out for the reason Ollama's
endpoint is suspect: none is documented, and each has changed shape within a
year. Anthropic's and OpenAI's APIs have nothing a normal key can ask; their
usage reports want an admin key and cover the whole organisation.

`LlmRegistry.usageOf` asks with the resolved key and a ten-second bound. An
endpoint that answers anything but a 200 holding an object throws, and the
registry gives it a `logFailure` line and shows nothing — a usage endpoint
that changed under us is otherwise indistinguishable from one with nothing to
say. `providerUsageProvider` is auto-disposed, so the section asks again each
time it is shown.

## A program in the model's place

`CliProvider` (`providers/cli.dart`) is the third kind beside the two wire
formats: another harness's command-line program — Claude CLI today, Codex
the obvious next — answering Entoli's turns under the user's own sign-in.
Its config is `LlmApi.claudeCli` with a `command` (a path, or a bare name
looked up on `PATH`, null for the subclass's `defaultCommand`) and an `env`
laid over the app's own environment; `baseUrl` is empty and no key is asked
for (`KeyFree`). `providerOf` reads it by API before anything else, so a
CLI entry is never mistaken for the endpoint its catalog id names. The
program is found on the login shell's `PATH` (`CliProvider.loginPath`, set
by `main` from the same capture the shell uses), since a desktop launch
inherits one that misses `~/.local/bin`. A default name found nowhere on
it falls back to a copy another app ships (`bundledCopies`): on macOS,
Claude Desktop keeps its own `claude` under
`~/Library/Application Support/Claude/claude-code/<version>/<build>/`,
replaced on each update, so the newest is looked up per session rather than
stored — run outside a Desktop session it signs in as any `claude` does. A phone runs no programs, so there
it offers no models, and the dialog offers the API only on a desktop.
What of the app's own environment reaches the program is the subclass's
(`inherits`): an Entoli started from inside a Claude Code session — a
Claude Code terminal, a Claude Desktop session — carries that session's
variables, `CLAUDECODE` among them, and `ClaudeCliProvider` hands on none
of its `CLAUDE*`, `ANTHROPIC_*` or `MCP_*` ones then, since they would make
its `claude` a child of that session: its id, its account email, its proxy
for the API.

**The split is interface against lifecycle.** `CliProvider` owns what every
such program shares: finding it, its environment, and `CliClient` — the
`LlmClient` that pools `CliSession`s. The loop resends the whole
conversation each step; the client finds the parked session whose `seen`
conversation the new one extends (by `CliClient.markOf`: role and ids,
text where there are no ids, since the loop keeps its own reasoning), with
the same `CliSessionSpec` — model, leading system text, tools, effort,
which a program is told once on its command line — and feeds it only the
rest. No such session means a fresh one, told the past as a transcript
(`transcriptOf`), since a program takes a new message and not a history it
did not live through. A session is parked the moment its completion is
read, so a consumer that stops on the reply does not take it down; one
stopped part-way is closed. Parked sessions go after ten minutes or past
four, and `close` takes every one down. What a session *is* belongs to the
subclass, through `start`.

`ClaudeCliProvider`'s session is one `claude -p` in stream-json on both
sides, run in one empty folder every session shares —
`<cache>/claude-cli/work/`, the cache `main` hands `ClaudeCliProvider` — so
no project's `CLAUDE.md` is picked up and what the CLI keeps per working
directory (its cache's MCP logs, its project entry in `~/.claude.json`) is
kept once rather than once per session; the files a session is handed sit
in `claude-cli/sessions/<id>/`, which goes with it. It runs with `--tools ""` (Claude's own tools off), `--permission-mode dontAsk`
over an allow list of Entoli's server alone — `--tools ""` leaves
`EndConversation` while MCP tools are present, and this refuses it and
anything else that slips through rather than asking — `--strict-mcp-config`,
`--no-session-persistence`, the system prompt by `--system-prompt-file`
(argv has a length limit and the prompt can pass it) and `--effort` from
the loop's word. Its `--include-partial-messages` lines are Anthropic's
raw stream events, so `AnthropicEventReader` — lifted out of
`AnthropicClient` for this — reads them into the same chunks.

**Entoli's tools reach it over MCP, and the call is held.** `McpToolBridge`
serves them on an ephemeral loopback port behind a random bearer token,
`tools/call` answered by nothing until the loop has run the tool: the
reply's `tool_use` ends the exchange with the calls (named without the
`mcp__entoli__` prefix), the CLI meanwhile waits on the bridge, and the
next step's tool results answer the held requests — paired to each
`tool_use` by name and input, since the MCP request does not carry the id.
That is how approvals, sub-agents and the rest of the loop stay Entoli's
while the conversation stays in one process with its cache. A call that
arrives before its reply has been read waits as an orphan. A reply the
CLI makes that the loop did not ask for (it ran something itself) marks
the session dead, and the next step starts a fresh one. `MCP_TOOL_TIMEOUT`
is set to a day, a tool being able to wait on the user. Closing is stdin
first, then SIGTERM, then SIGKILL, three seconds apart, with every held
call failed so the CLI is not left waiting on it.

The process and the bridge are ports a session is handed:
`ClaudeCliProvider.over` takes a `LaunchCli` (the real one is
`launchProcess`, a `CliProcess` over `dart:io`'s) and a `BindToolBridge`
(`McpToolBridge.bind`). What the bridge decides is `McpToolRoutes`, a
JSON-RPC request in and its answer out, and `McpToolBridge` is that behind
a socket — the token check and the HTTP translation, which no test covers,
since no test binds a port. The session's tests run over a fake process
and a bridge with no socket under it, playing the CLI by printing its
stream events and calling the routes.

## Errors, and how long the UI waits

Failures are reported as they happen: a rejected key or a bad request reaches
`ErrorEvent` on the first attempt, and a retryable one (429, 5xx, a connection
that never opened) emits `RetryEvent` the instant it fails. `ErrorEvent` carries
whether the failure was retryable — read off the exception the query died on —
and that flag is what the controller's automatic retry rounds ask before
re-entering `resume` (see `lib/domain/room/AGENTS.md`, "Automatic retry rounds");
`_fail`, for a failure the turn never reached a model through, leaves it false.
A request that died mid-stream is retryable too, and safe to resume, because
resuming appends to the same reply rather than starting another.

**The parent agent spends one attempt per request**, `maxAttempts: 1`: the
controller owns the patience, and the two retrying would be the same patience
twice. Sub-agents keep the four-attempt default, a failed worker being a tool
result the parent can redo rather than a turn to give up on. Four attempts with
1s/2s/4s backoff remains what a sub-agent's request gets before it reports
failure upward. A 429 takes a different path: a `RateLimitGate` shared across the parent
and every sub-agent coordinates backoff so a fan-out pauses as one rather than
each-retry-into the same limit (see "Reaching a provider"). 429 retries
continue for `BuiltinOptions.rateLimitRetryBudget` (5 min default) with
exponential backoff capped at 60s, and never spend the parent's single attempt
— so a rate-limited turn is still governed here, not by the controller's
setting. Where no gate is present (tests against a raw
`FakeLlmClient`), 429s fall back to the per-agent path.

Because nothing is hidden, silence only ever means work, and the UI never
gives up on a turn on its own — the user cancels. A `RetryEvent` is
turn-scoped view state, never a message part, so it is not persisted.
