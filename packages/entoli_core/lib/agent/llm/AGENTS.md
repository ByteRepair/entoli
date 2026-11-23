# The model clients

## Reaching a provider

`LlmClient` has two wire implementations: `OpenAiClient` (`/chat/completions` —
and so also OpenRouter, Groq, Ollama Cloud, ollama, LM Studio, vLLM) and
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

A model that thinks between tool calls is handed its earlier reasoning back
as text, on the assistant message it came with. DeepSeek's thinking mode
requires it: on a request carrying `tools`, the `reasoning_content` of every
earlier turn goes back (not only the current tool loop's), and the official API
answers 400 without it. Without `tools` it is ignored, so it is sent only
beside them. The projection already keeps `LlmMessage.reasoning` for every
reply, live and reloaded, so the encoder was the only thing missing.
`OpenAiClient.reasoningFieldOf` names the field per model and per whether the
request carries tools, and null sends nothing. The rule is the host's, so the
provider answers it, not the encoder. A strict host rejects a field it does not
know, so the field comes from something explicit and never from a model's name:

- **models.dev's `interleaved.field`**, which `ModelInfo.interleavedField`
  keeps (and the catalog cache writes back). `OpenAiCompatibleProvider` reads
  it, so DeepSeek's own endpoint, Z.ai and any hand-typed host models.dev
  describes get `reasoning_content`. OpenAI's models name no field, and
  `OpenAiProvider`'s client takes none. `reasoning_details` is OpenRouter's
  structured block list, not the text kept here, so it is not replayed.
- **Ollama, local and Cloud, by class.** Its compat layer reads earlier
  thinking from `reasoning` and silently drops `reasoning_content`. That is
  how a whole DeepSeek V4 Pro chat through Ollama Cloud ran each of its
  tool-calling steps without the reasoning of the ones before, with no error
  to say so. Both classes take `OllamaCompat`, which answers `reasoning` for
  every model beside tools, and the server's template decides what the model
  sees of it.

Its compat surface has no audio endpoints, so speech and transcription are
native `generateContent` calls in `GeminiClient` too — see "A provider's
models" in `packages/entoli_voice/lib/AGENTS.md`.

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

The welcome tour offers a few of them by the service's name rather than the
API's — ChatGPT is Codex CLI, Claude Pro is Claude CLI — to someone who knows
what they pay for and not what answers for it; no API key is asked for there,
the APIs being Advanced's. A class offered there takes
`OfferedByName`, whose `serviceName` and `connectHint` are its words on the
tour, and `welcomeProviders` is which of them and in what order; one its
`supported` says this build cannot reach (a CLI where there is no guest) is
not drawn.
Connecting one is its preset in the ordinary provider dialog, adopted
(`upsertProvider`'s `adopt`): it answers new chats, titles and the classifier
at the preset's defaults, whatever was picked before, and nothing on the tour
asks for a model.

`providerOf`, the presets and the tour's list are the app's
(`lib/data/builtin/llm/providers/presets.dart`), beside the CLI providers in
`lib/data/builtin/llm/AGENTS.md`.

**What a model can do is its type.** A provider `serve`s a model id as one
`Model` per thing it does
(`packages/entoli_core/lib/model/model_capability.dart`): a `ChatModel`, an
`ImageModel`, a `TranscriptionModel`, a `SynthesisModel`. `LlmProvider` serves
chat alone; `OpenAiCompatibleProvider` adds the other three over its client's
image and audio endpoints, as the model's catalog entry describes it, or all of
them for an id the catalog does not describe. `OnDeviceProvider` serves the
downloaded text models and the installed voice models, which the platform's
`Voice` runs. A model holds what runs it, so the provider says what exists and
never runs anything. The backend, the voice gates and the pickers resolve a pick
to the kind they need (`resolve<T>`), never asking the provider's or the
client's type; no transcription model is served where `ModelHost.cutsUtterances`
is false. A key can be left out and named as `apiKeyEnv` instead, which is how
one already exported stays out of the file. `LlmRegistry` builds a client per
provider and rebuilds it when the URL or key changes; a provider that lists no
models is asked, and one that cannot answer contributes nothing rather than
failing the whole list. The on-device server and Apple's model are providers
too, whose `client` is the pool or the channel — which is how "may not be
answering yet" arrives without the registry knowing there is such a thing. See
"Running a model on the device" in `lib/data/local/AGENTS.md`.

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

## How long a reply may be

Settings > LLMs > Maximum response length is two settings: a number (8192 by
default, at least 1024) and a switch over it. Off, every model writes to its
own limit — models.dev's `limit.output`, the catalog the app already keeps —
and the number is only the fallback for a model the catalog does not list. On,
the number caps every reply, whatever the model could write.

The backend puts the facts beside each other once per turn — the number, the
switch, and the model's own limit — as an `LlmOutputLimit` on every request,
the sub-agents' included, and each client decides what its API is sent:

- **Anthropic** must name `max_tokens`, so it sends the cap, else the model's
  own, else the fallback. Thinking goes inside a known limit, leaving the reply
  at least 1024; a fallback gives the reply its own room on top of the thinking,
  as the old fixed 8192 did; a cap too small for both drops the thinking rather
  than send a request Anthropic refuses.
- **The OpenAI shape** sends nothing unless capped: unasked, the model writes to
  its own limit, and there is no number to guess. Capped, `max_tokens` —
  `max_completion_tokens` on OpenAI's own API (`maxTokensField`), which its
  reasoning models require. llama.cpp is this client too.
- **Claude CLI** is told the cap as `CLAUDE_CODE_MAX_OUTPUT_TOKENS` when it
  starts, so a session is reused only under the same cap; uncapped, Claude Code
  writes to its own model's limit.
- **MLX** is always sent a number, its Swift half having to stop somewhere;
  **Apple's model** is sent the cap alone, as `maximumResponseTokens`. Neither
  native half decides whether a reply was cut off: `ChannelGeneration` knows
  the `maxTokens` it sent and the `outputTokens` the reply came back with, and
  a reply that reached the one is `truncated` there, once, in Dart.
- **Codex CLI** is the exception the settings row names: Codex builds its own
  requests, which carry no length field, and its config has no setting for one.

A high `max_tokens` costs nothing it does not use: Anthropic's output rate
limit counts the tokens generated, not the ones asked for. What a high ceiling
does allow is a reply that runs away, which the switch is for.

## How much of an allowance is spent

`LlmProvider.usage` answers it, as a list of `ProviderUsage`s
(`packages/entoli_core/lib/model/provider_usage.dart`), of two kinds. A
`UsageWindow` is an allowance: a label in the provider's own period, what is
`used` of a `max`, the unit the two are counted in, and when it starts again
where the provider says. `used` is always what is gone — a provider that reports
what is left is converted where it is read — and a max rather than a percentage,
because what a provider counts is not always a share: a dollar cap is a number
of dollars. A `CreditBalance` is money with no allowance behind it, credits
bought rather than granted, so it is what is left and nothing to measure it
against. The default is nothing, which is what most providers have to say; the
Providers section in Settings draws a line per entry under the row, a bar under
each window, and nothing at all for an empty list.

**Only where the answer is the provider's to keep stable.** Four say it:

- **OpenRouter** — `/key`, documented: the key's spending cap, what is left of
  it and whether it resets daily, weekly or monthly. Its periods are UTC's, so
  the reset is computed; a key with no cap has nothing to show.
- **Groq** — no endpoint, but every reply carries documented
  `x-ratelimit-*` headers: the requests a day and the tokens a minute.
- **OpenAI** — the same headers, documented, with the requests and tokens a
  minute and the project's tokens a minute where a project-scoped limit
  applies. Its spend is in usage reports that want an admin key and cover the
  whole organisation, so the paces are what a normal key has. Only the preset
  gets this; a custom OpenAI-compatible endpoint says nothing of the sort.
- **Ollama Cloud** — `ollama.com/api/balance`, documented (outside the `/v1`
  the chat endpoint is under): the plan's included credits, an allowance in
  dollars that resets at the end of its monthly period, and the purchased
  credits as a balance, left out at zero since most accounts never buy any.
  A plan from before credits answers with its session and weekly limits as
  percentages remaining in the included credits' place, which become shares.
  `/api/usage` is not it: that is the request history, and the session and
  weekly fractions it once carried went in October 2026.

The two that say it on their replies are one `RateLimitClient` each, a
`ReportsUsage` — a client that learns usage from its replies rather than a
provider that asks. `OpenAiClient.responded` hands it a reply's headers, and
the subclass names the pairs its host documents and what period each is in,
since the headers' names do not say. Nothing until a reply has arrived.

**A pace is shown, and only while it is true.** A limit counted per minute is
not an allowance: it is how fast, not how much, and the reading a reply left
stops being true within the minute. It is still worth seeing — it is what a
turn that waits on a 429 ran into — so it is shown, labelled with its minute,
and a reading is dropped once the reset its reply named has passed, when the
limit is whole again. The same holds for every window read off a reply. A pace
with no reset is not kept, since nothing says how old it is.

Z.ai's coding-plan quota, Claude CLI's `rate_limit_event` and Codex's
`account/rateLimits/read` exist and are left out: none is documented, and
each has changed shape within a year. Anthropic's usage and cost reports want
an admin key and cover the whole organisation; its ordinary Messages API has
no account-allowance endpoint.

`LlmRegistry.usageOf` asks the provider with the resolved key, bounded at ten
seconds, and where it has nothing to ask reads the client its turns already
run over, if that client `ReportsUsage` — never one built to ask, since a
client that has run no turn has heard nothing. An endpoint that answers
anything but a 200 holding an object throws (through `sendChecked`, so the
provider's own reason comes with it), and the registry gives it a
`logFailure` line and shows nothing — a usage endpoint that changed under us
is otherwise indistinguishable from one with nothing to say. The UI asks
through `AgentBackend.providerUsage`, the seam a fake backend answers in
tests; `providerUsageProvider` asks again when the section comes back to a
provider a minute or more after it last asked, which keeps Ollama's ten
balance requests a minute out of reach of someone moving between settings
categories.

## Errors, and how long the UI waits

Failures are reported as they happen: a rejected key or a bad request reaches
`ErrorEvent` on the first attempt, and a retryable one (429, 5xx, a connection
that never opened) emits `RetryEvent` the instant it fails. `ErrorEvent` carries
whether the failure was retryable — read off the exception the query died on —
and that flag is what the controller's automatic retry rounds ask before
re-entering `resume` (see `packages/entoli_core/lib/model/room/AGENTS.md`,
"Automatic retry rounds"); `_fail`, for a failure the turn never reached a model
through, leaves it false. A request that died mid-stream is retryable too, and
safe to resume, because resuming appends to the same reply rather than starting
another.

**The parent agent spends one attempt per request**, `maxAttempts: 1`: the
controller owns the patience, and the two retrying would be the same patience
twice. Sub-agents keep the four-attempt default, a failed worker being a tool
result the parent can redo rather than a turn to give up on. Four attempts with
1s/2s/4s backoff remains what a sub-agent's request gets before it reports
failure upward. A 429 takes a different path: a `RateLimitGate` shared across
the parent and every sub-agent coordinates backoff so a fan-out pauses as one
rather than each-retry-into the same limit (see "Reaching a provider"). 429
retries continue for `BuiltinOptions.rateLimitRetryBudget` (5 min default) with
exponential backoff capped at 60s, and never spend the parent's single attempt —
so a rate-limited turn is still governed here, not by the controller's setting.
Where no gate is present (tests against a raw `FakeLlmClient`), 429s fall back
to the per-agent path.

Because nothing is hidden, silence only ever means work, and the UI never
gives up on a turn on its own — the user cancels. A `RetryEvent` is
turn-scoped view state, never a message part, so it is not persisted.
