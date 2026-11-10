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

A model that thinks between tool calls is handed its earlier reasoning back
as text, on the assistant message it came with. DeepSeek's thinking mode
requires it: on a request carrying `tools`, the `reasoning_content` of every
earlier turn goes back (not only the current tool loop's), and the official API
answers 400 without it. Without `tools` it is ignored, so it is sent only
beside them. The projection already keeps `LlmMessage.reasoning` for every
reply, live and reloaded, so the encoder was the only thing missing.
`OpenAiClient.reasoningFieldOf` names the field per model, and null sends
nothing. A strict host rejects a field it does not know, so the field comes
from something explicit and never from a model's name:

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
  to say so. Both classes override `replayedReasoningField` to `reasoning` for
  every model, and the server's template decides what the model sees of it.

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

The welcome tour offers a few of them by the service's name rather than the
API's — ChatGPT is Codex CLI, Claude Pro is Claude CLI — to someone who knows
what they pay for and not what answers for it; no API key is asked for there,
the APIs being Advanced's. A class offered there takes
`OfferedByName`, whose `serviceName` and `connectHint` are its words on the
tour, and `welcomeProviders` is which of them and in what order; one its
`supported` says this platform cannot reach (a CLI on a phone) is not drawn.
Connecting one is its preset in the ordinary provider dialog, adopted
(`upsertProvider`'s `adopt`): it answers new chats, titles and the classifier
at the preset's defaults, whatever was picked before, and nothing on the tour
asks for a model.

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
(`lib/domain/provider_usage.dart`), of two kinds. A `UsageWindow` is an
allowance: a label in the provider's own period, what is `used` of a `max`,
the unit the two are counted in, and when it starts again where the provider
says. `used` is always what is gone — a provider that reports what is left is
converted where it is read — and a max rather than a percentage, because what
a provider counts is not always a share: a dollar cap is a number of dollars.
A `CreditBalance` is money with no allowance behind it, credits bought rather
than granted, so it is what is left and nothing to measure it against. The
default is nothing, which is what most providers have to say; the Providers
section in Settings draws a line per entry under the row, a bar under each
window, and nothing at all for an empty list.

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

## A program in the model's place

`CliProvider` (`providers/cli.dart`) is the third kind beside the two wire
formats: another harness's command-line program — Claude CLI and Codex
CLI — answering Entoli's turns under the user's own sign-in.
Its config is `LlmApi.claudeCli` or `LlmApi.codexCli` with a `command` (a path, or a bare name
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
stored — run outside a Desktop session it signs in as any `claude` does. Android runs the
programs in its Linux (below); iOS runs none, so there a CLI entry offers no
models and the dialog offers the API only where `supported` says it can run.
What of the app's own environment reaches the program is the subclass's
(`inherits`): an Entoli started from inside a Claude Code session — a
Claude Code terminal, a Claude Desktop session — carries that session's
variables, `CLAUDECODE` among them, and `ClaudeCliProvider` hands on none
of its `CLAUDE*`, `ANTHROPIC_*` or `MCP_*` ones then, since they would make
its `claude` a child of that session: its id, its account email, its proxy
for the API.

Neither program's models are in models.dev, so what the app knows of one —
its context window above all — is the subclass's `knownModels`: each a
`ModelInfo` with its `context` (200k for Claude's aliases, 272k for Codex's),
the user's own `customModels` first. A provider answers for one model
through `LlmProvider.modelInfo`, which is `modelInfoOf` unless a class knows
of models no catalog lists, and `CliProvider` falls back to `knownModels`
there. The backend asks an endpoint it holds rather than `modelInfoOf`
directly — `contextWindowOf`, which the context page and auto-compaction
read, and `_resolveModel`'s image and PDF gate — so a chat on either program
reports the window it has rather than the 128k guess. The pickers, which hold
a config and no endpoint, still ask `modelInfoOf`, which only costs them a
display name.

**Entoli keeps its own copy of each program, and signs it in.** `ownCopy` is
`<cache>/<workFolder>/bin/<command>`, the cache being where a copy that goes
missing is fetched again rather than lost. `install` asks the subclass's
`latestRelease` for this machine's build (`CliProvider.abi`, which a test
names): Claude CLI's is the program itself from
`downloads.claude.ai/claude-code-releases` — `latest` for the version, that
version's `manifest.json` for each platform's SHA-256 and size, the musl
build on a musl Linux — taken as it is rather than run as an installer, since
`claude install` would only add a launcher on the user's `PATH`; Codex CLI's
is two assets GitHub's releases API names for the target (musl on Linux, a
zip on Windows, a tarball elsewhere) — `codex` and `codex-code-mode-host`,
its `companions`, the program code mode runs the model's scripts in and which
Codex looks for beside itself. Without it every `exec` a code-mode model such
as `gpt-6-luna` makes fails inside Codex, and with it every one of Entoli's
tools called from such a script, before anything reaches the loop. Each
asset's `digest` is its hash, and a release stating none is refused; a copy
missing a companion is not `installed`, so it is fetched again. Each file is checked against its hash,
taken out of its packing (`CliPacking`: `BareProgram`, `TarGzProgram`,
`ZipProgram`, read in Dart so no platform needs a `tar`), given its execute
bit, and renamed into place, the CLI's own last, so a copy in use is
replaced whole. `locate`
prefers it over the default name on `PATH`, which is what makes the copy the
tour signed in the one every session runs. Signing in is the program's own:
`statusArguments` exit 0 when signed in (`claude auth status`, `codex login
status`), and `CliSignIn` runs `signInArguments` (`claude auth login
--claudeai`, `codex login`), takes the first `https` link it prints — error
output read a whole line at a time, so a link split between two writes is
not taken at its first half — and ends signed in when the program exits 0 and
its status agrees. `signOutArguments` (`claude auth logout`, `codex
logout`) are what Sign in again runs first.

**Each provider is its own account, apart from the user's.** Under
`<cache>/<workFolder>/`, `bin/` is the program, shared; `data/<provider-id>/`
is what the program keeps — its sign-in, settings, history and caches — in
place of the user's `~/.claude` or `~/.codex`; `work/<provider-id>/` is the
empty folder that provider's sessions run in, kept apart from `data/` so the
two never mix. `homeEnvironment` is what tells the program: `CLAUDE_CONFIG_DIR`,
which moves `.claude.json` with it and on macOS names the Keychain entry
`Claude Code-credentials-` and the first eight hex of the folder's SHA-256, so
each folder is its own Keychain sign-in; and `CODEX_HOME`, which holds
`auth.json`. An entry's own `env` wins over it. So two entries on one program
are two accounts, and signing in through Entoli never signs the user's own
`claude` or `codex` in or out. The folders are named by the entry's id, which
is why a CLI entry has its id before it can sign in — `editProvider` and the
tour's connect give a new one its id when they open, and take its folders back
when it is cancelled — and the settings notifier's `setProviders` `forget`s them when the entry is removed, beside its stored key.
In the cache rather than the data directory, deliberately: the data directory
is backed up and synced, and a sign-in is a secret. A cleared cache costs a
sign-in, not a leaked token. `withConfig` reads one program for another entry
with the same ports, which is how the UI gets an entry's program from
`cliProgramsProvider`.

**On Android the program runs in the Linux.** Android's own processes are
not Linux's, so `main` sets `CliProvider.guest` to a `ProotCliGuest` where the
build carries proot, and every start — a session, a status check, a sign-in
— goes through `CliProvider.run`, which hands the program's own words to the
guest. `prootProgram` (`data/local/proot.dart`) is the terminal driver's proot
running one program rather than a shell, with the program's cache folder
bound at its own host path, so its file, its `data/<id>/`, its `work/<id>/` and
a Claude session's files are one path inside the guest and out and nothing is
translated; the guest's `PATH`, `HOME` and the subclass's `guestEnvironment`
stand in for the app's environment, which is Android's. The rootfs is looked
up at each start, so the one the first-run setup installs is used without a
restart, and with none the start says to install one. The builds are the musl
ones (`linux-arm64-musl`, `aarch64-unknown-linux-musl`), which is what Alpine
runs; Claude CLI's docs ask for `libgcc`, `libstdc++` and the system's
`ripgrep` on a musl Linux, so its `guestPackages` are `apk add`ed in the guest
before the program is put in place, and a failure there is a failed install.
The sign-in's callback is the program's own `localhost` server, which proot
shares with the phone, so the phone's browser reaches it. iOS has no guest:
its Alpine is iSH's, which emulates 32-bit x86 and loads no 64-bit program,
and neither program is built for anything else. What is not known is how
either behaves under proot on a real device — Codex's own exec sandbox above
all; nothing here has run on one.

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
subclass, through `start`. Both programs' sessions are a
`CliProcessSession`: one process speaking JSON a line at a time, whose
lifecycle — the exchange in progress, held calls against new input, the
end, the exit and the close — is written once there; a subclass says what
a line means and how input and results are written.

`ClaudeCliProvider`'s session is one `claude -p` in stream-json on both
sides, run in one empty folder every session of the entry shares —
`<cache>/claude-cli/work/<provider-id>/`, the cache `main` hands
`CliProvider` — so no project's `CLAUDE.md` is picked up and what the CLI
keeps per working directory (its cache's MCP logs, its project entry in
`.claude.json`) is kept once rather than once per session; the files a session is handed sit
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
stream events and calling the routes. `CodexCliProvider.over` takes the
`LaunchCli` alone, and its tests play the app-server over the same fake
process, line by line.

**Codex CLI is a server rather than a pipe of messages.**
`CodexCliProvider`'s session is one `codex app-server`, Codex's JSON-RPC
over stdio, holding one ephemeral thread run in `<cache>/codex-cli/work/<provider-id>/`:
Entoli's system prompt is the thread's `baseInstructions`, each new user
message a `turn/start`, and the reply streams back as item notifications.
Entoli's tools are the thread's dynamic tools, so no MCP bridge is needed:
Codex calls one with an `item/tool/call` request carrying the call's id,
and waits for the response. A reply ends where calls arrive. Those
read with the same output are one reply (the hand-out waits one
event-loop turn, `Timer.run`, not a duration), and one that arrives after
its reply went out is the next reply. That is the one rule that also
covers code mode, where a model such as `gpt-6-luna` runs a script in
Codex's own `exec` tool and calls Entoli's tools from inside it, so the
model's response never names them. Code mode cannot be switched off: with
its host disabled, those models' `exec` calls fail.

What is switched off is by `-c` (`argumentsFor`): Codex's feature
flags by `features.<name>=false`, since `--disable` refuses a name a later
release has dropped where config only warns; web search; the
request-user-input tool; the bundled skills; and `notify`, which the ChatGPT
app points at a program of its own. The thread has no environments and a
read-only sandbox, which leaves `apply_patch` offered but unable to write.
MCP servers in the user's `config.toml` (the ChatGPT app adds a
`node_repl`) are switched off one by one by name (`userMcpServers`):
overriding the table with an empty one keeps every server. Any request
other than a tool call — an approval, a question — is answered with an
error, there being nobody to ask. The program a default name falls back to
is the ChatGPT app's copy. The models offered are what a ChatGPT account
was offered when this was written, and depend on the plan; the user adds
any other as the provider's own.

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
