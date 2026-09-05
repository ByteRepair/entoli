# The model clients

## Reaching a provider

`LlmClient` has two implementations: `OpenAiClient` (`/chat/completions` — and
so also OpenRouter, Groq, Ollama Cloud, ollama, LM Studio, vLLM) and
`AnthropicClient` (`/messages`). Anthropic is not reachable through the first
one: its system prompt is a parameter rather than a message, tool results ride
inside user turns, and consecutive results have to be folded into one turn
because a turn holding N `tool_use` blocks must be answered by exactly one turn
holding all N results.

`OpenAiClient` has one flag that is not about the shape of the wire:
`returnProgress` asks for llama.cpp's `prompt_progress` frames, which arrive
while the prompt is still being read and become `LlmPromptProgress`. Off by
default and turned on only by `LocalPoolClient`, because a hosted provider is
entitled to reject a body field it has never heard of and the strict ones do.
The frame arrives with `choices` empty, so it is read before the guard that
skips a frame with nothing in it — a detail worth knowing because moving that
read below the guard silently loses every one of them.

Thinking is handed back with the `signature` it arrived with. With thinking
enabled, Anthropic rejects a tool-use turn whose thinking was dropped, so
`LlmMessage` carries `reasoningSignature` and `ReasoningPart` carries
`signature` for no other reason — see "The projection". Enabling thinking also
pins the temperature at 1, so the two are never sent together.

Providers are configured in `settings.json` under `llmProviders` — id, API
shape, base URL, key, and an optional model list — and `llmProviderPresets`
fills in the endpoints worth naming so that adding one is a key rather than a
URL nobody remembers. A key can be left out and named as `apiKeyEnv` instead,
which is how one already exported stays out of the file. `LlmRegistry` builds a
client per endpoint and rebuilds it when the URL or key changes; a provider that
lists no models is asked, and one that cannot answer contributes nothing rather
than failing the whole list. What it builds a client *with* is the endpoint's
own business: an `LlmEndpoint` is a config and, where reaching it is not the
ordinary thing, the client to reach it with — which is how the on-device
server's "may not be answering yet" arrives without the registry knowing there
is such a thing. See "Running a model on the device" in
`lib/data/local/CLAUDE.md`.

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

## Errors, and how long the UI waits

Failures are reported as they happen: a rejected key or a bad request reaches
`ErrorEvent` on the first attempt, and a retryable one (429, 5xx, a connection
that never opened) emits `RetryEvent` the instant it fails. `ErrorEvent` carries
whether the failure was retryable — read off the exception the query died on —
and that flag is what the controller's automatic retry rounds ask before
re-entering `resume` (see `lib/ui/chat/CLAUDE.md`, "Automatic retry rounds");
`_fail`, for a failure the turn never reached a model through, leaves it false.
A request that died mid-stream is retryable too, and safe to resume, because
resuming appends to the same reply rather than starting another.

**The parent agent spends one attempt per request**, `options.parent`: the
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
