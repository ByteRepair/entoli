# The CLI providers

## A program in the model's place

The clients, `LlmProvider` and the registry are the core's: see
`packages/entoli_core/lib/agent/llm/AGENTS.md`.

`CliProvider` (`providers/cli.dart`) is the third kind beside the two wire
formats: another harness's command-line program — Claude CLI, Codex CLI,
Copilot CLI and Antigravity CLI — answering Entoli's turns under the user's
own sign-in. Its config is the program's `LlmApi` with a `command` (a path,
or a bare name looked up on `PATH`, null for the subclass's `defaultCommand`)
and an `env` laid over the app's own environment; `baseUrl` is empty and no key
is asked for (`KeyFree`). `providerOf` reads it by API before anything else, so
a CLI entry is never mistaken for the endpoint its catalog id names. The program
is found on the login shell's `PATH` (the `HostCliGuest`'s `loginPath`, set by
`main` from the same capture the shell uses), since a desktop launch inherits
one that misses `~/.local/bin`. A default name found nowhere on it falls back to
a copy another app ships (`bundledCopies`): on macOS, Claude Desktop keeps its
own `claude` under `~/Library/Application
Support/Claude/claude-code/<version>/<build>/`, replaced on each update, so the
newest is looked up per session rather than stored — run outside a Desktop
session it signs in as any `claude` does. A phone runs the programs in its Linux
(below); only an Android build with no proot has nowhere to run one, and there a
CLI entry offers no models and the dialog offers the API only where `supported`
says it can run. What of the app's own environment reaches the program is the
subclass's (`inherits`): an Entoli started from inside a Claude Code session — a
Claude Code terminal, a Claude Desktop session — carries that session's
variables, `CLAUDECODE` among them, and `ClaudeCliProvider` hands on none of its
`CLAUDE*`, `ANTHROPIC_*` or `MCP_*` ones then, since they would make its
`claude` a child of that session: its id, its account email, its proxy for the
API.

Neither program's models are in models.dev, so what the app knows of one —
its context window above all — is the subclass's `knownModels`: each a
`ModelInfo` with its `context` (200k for Claude's aliases, 272k for Codex's),
the user's own `customModels` first. A provider answers for one model
through `LlmProvider.modelInfo`, which is `modelInfoOf` unless a class knows
of models no catalog lists, and `CliProvider` falls back to `knownModels`
there. The backend asks an endpoint it holds rather than `modelInfoOf`
directly — `contextWindowOf`, which the context page and auto-compaction
read, and `_resolveModel`'s image and PDF gate — so a chat on either program
reports the window it has rather than the Total Context guess. The pickers,
which hold a config and no endpoint, still ask `modelInfoOf`, which only costs
them a display name.

**Entoli keeps its own copy of each program, and signs it in.** `ownCopy` is
`<cache>/<workFolder>/bin/<command>`, the cache being where a copy that goes
missing is fetched again rather than lost. `install` asks the subclass's
`latestRelease` for the build its guest runs (`CliGuest.abi`, a
`HostCliGuest`'s own unless a test names one): Claude CLI's is the program
itself from `downloads.claude.ai/claude-code-releases` — `latest` for the
version, that version's `manifest.json` for each platform's SHA-256 and size,
the musl build where the guest is musl (`CliGuest.musl`) — taken as it is rather
than run as an installer, since `claude install` would only add a launcher on
the user's `PATH`; Codex CLI's is two assets GitHub's releases API names for the
target (musl on Linux, a zip on Windows, a tarball elsewhere) — `codex` and
`codex-code-mode-host`, its `companions`, the program code mode runs the model's
scripts in and which Codex looks for beside itself. Without it every `exec` a
code-mode model such as `gpt-6-luna` makes fails inside Codex, and with it every
one of Entoli's tools called from such a script, before anything reaches the
loop. Each asset's `digest` is its hash, and a release stating none is refused;
a copy missing a companion is not `installed`, so it is fetched again. Each file
is checked against its hash, taken out of its packing (`CliPacking`:
`BareProgram`, `TarGzProgram`, `ZipProgram`, read in Dart so no platform needs a
`tar`), given its execute bit, and renamed into place, the CLI's own last, so a
copy in use is replaced whole. `locate` prefers it over the default name on
`PATH`, which is what makes the copy the tour signed in the one every session
runs. Signing in is the program's own: `statusArguments` exit 0 when signed in
(`claude auth status`, `codex login status`), and `CliSignIn` runs
`signInArguments` (`claude auth login --claudeai`, `codex login`), takes the
first `https` link it prints — error output read a whole line at a time, so a
link split between two writes is not taken at its first half — and ends signed
in when the program exits 0 and its status agrees. `signOutArguments` (`claude
auth logout`, `codex logout`) are what Sign in again runs first.

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
is why a CLI entry has its id before it can sign in — the provider dialog gives
a new one its id as it opens, and takes its folders back when it is left unsaved
(`forgetCliEntry` in `editProvider`) — and the settings notifier's
`setProviders` `forget`s them when the entry is removed, beside its stored key.
In the cache rather than the data directory, deliberately: the data directory is
backed up and synced, and a sign-in is a secret. A cleared cache costs a
sign-in, not a leaked token. `withConfig` reads one program for another entry
with the same ports, which is how the UI gets an entry's program from
`cliProgramsProvider`.

**Where a program runs is its `CliGuest`, and nothing else.** A guest
says the ABI its programs are built for, whether they are musl, what they
start with, how packages go in, and how a process is started; every start —
a session, a status check, a sign-in, a package install — goes through
`CliProvider.run` to it. The guests are `entoli_shell`'s
(`packages/entoli_shell/lib/cli_guest.dart`, `proot.dart`, `ish_pipe.dart`).
`main` sets `CliProvider.platformGuest` once, from the device's `LinuxHost`
(`cliGuestOf` in `entoli_shell.dart`): a
`HostCliGuest` on a desktop, whose programs are this machine's processes
with its environment as the subclass's `inherits` passes it on; a
`ProotCliGuest` on Android; an `IshCliGuest` on iOS; none on an Android
build with no proot, which is the one place `supported` is false. A
provider given a guest of its own (`ClaudeCliProvider.over`) runs there
instead, which is how a test runs one over a fake.

**A program can be started on a terminal.** `start(…, terminal: true)` runs it
on one where the guest has one to give (`hasTerminal`), each guest its own
way through `spawn(…, terminal:)`. iOS's is the bridge's: one of iSH's own
pseudo-terminals, made the way iSH's app makes its Terminal's
(`pty_open_fake`), as the program's stdio and controlling terminal, whose
screen is the session's stdout pipe and whose keyboard is a thread of the
bridge's typing the stdin pipe into it, the way `tty-real.c`'s thread types
the real one. Line discipline, echo, termios and the window size are iSH's
tty layer, nothing in the guest stands between, and the caller only ever
writes a host pipe. Android's is util-linux's `script` under proot
(`LinuxCliGuest.underScript`), installed from Alpine's `util-linux-misc` the
first time it is asked for, a real kernel's pseudo-terminal being what proot
has; the system's own `script` on macOS and on a Linux that has it; none on
Windows, which keeps pipes. It is given a
wide size, so a program does not wrap a long link across lines. The process
comes back a `TerminalCliProcess`: what it prints arrives without the
terminal's escapes or line-ending carriage returns, and a line written to it
ends in a carriage return, which is Enter to a program reading keys. The
sign-in runs this way, since Claude CLI reads a pasted code only as keys
from a terminal and takes nothing written to a pipe.

**A Linux of the app's own has no browser, so its programs are given the
app's.** On a terminal there (`LinuxCliGuest.withBrowser`), `BROWSER` names
`/usr/local/bin/entoli-open`, written in the guest where it is missing, which
prints `entoli-open` and the address to the terminal. The sign-in takes a page
named that way over the first link the program prints, in whichever order they
come: Claude CLI asks its browser for the page whose callback reaches its own
`localhost` listener, which finishes the sign-in with no code, and prints the
page that shows a code only as a fallback.

The two phones' guests are `LinuxCliGuest`s: Alpine's `PATH`, `HOME` and
`LANG` and the subclass's `guestEnvironment` stand in for the app's
environment, which is Android's or iOS's; their programs are the musl
builds; and packages go in with `apk`. The rootfs is the one the Terminal
settings picked, looked up at each start, so the one the first-run setup
installs is used without a restart, and with none the start says to
install one.

`ProotCliGuest` starts the program under proot as a process of the phone:
`prootProgram` (`packages/entoli_shell/lib/proot.dart`) is the terminal driver's proot
running one program rather than a shell, with the program's cache folder
bound at its own host path, so its file, its `data/<id>/`, its `work/<id>/`
and a Claude session's files are one path inside the guest and out and
nothing is translated. Its builds are the arm64 ones (`linux-arm64-musl`,
`aarch64-unknown-linux-musl`). Claude CLI's docs ask for `libgcc`,
`libstdc++` and the system's `ripgrep` on a musl Linux, so its
`guestPackages` are `apk add`ed in the guest before the program is put in
place, and a failure there is a failed install. The sign-in's callback is
the program's own `localhost` server, which proot shares with the phone, so
the phone's browser reaches it. What is not known is how either behaves
under proot on a real device — Codex's own exec sandbox above all; nothing
here has run on one.

`IshCliGuest` starts it inside the emulator (`GuestCliProcess`, the iSH
bridge's pipe session), on the x86-64 core: its builds are the x86-64 ones,
whatever the iPhone is, and it runs only in a Linux built for that — the
x86-64 Alpine. The emulator sees the app's data directory at its own path,
which is why iOS keeps the programs' cache there (`cliCacheRoot`) rather
than in the OS cache, and why nothing needs binding.

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
`.claude.json`) is kept once rather than once per session; the files a session
is handed sit in `claude-cli/sessions/<id>/`, which goes with it. It runs with
`--tools ""` (Claude's own tools off), `--permission-mode dontAsk` over an allow
list of Entoli's server alone — `--tools ""` leaves `EndConversation` while MCP
tools are present, and this refuses it and anything else that slips through
rather than asking — `--strict-mcp-config`, `--no-session-persistence`, the
system prompt by `--system-prompt-file` (argv has a length limit and the prompt
can pass it) and `--effort` from the loop's word. Its
`--include-partial-messages` lines are Anthropic's raw stream events, so
`AnthropicEventReader` — lifted out of `AnthropicClient` for this — reads them
into the same chunks.

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

Where it runs and the bridge are ports a session is handed:
`ClaudeCliProvider.over` takes a `CliGuest` (a test's is a `HostCliGuest`
over a fake `LaunchCli`; the real one launches `launchProcess`, a
`CliProcess` over `dart:io`'s) and a `BindToolBridge`
(`McpToolBridge.bind`). What the bridge decides is `McpToolRoutes`, a
JSON-RPC request in and its answer out, and `McpToolBridge` is that behind
a socket — the token check and the HTTP translation, which no test covers,
since no test binds a port. The session's tests run over a fake process
and a bridge with no socket under it, playing the CLI by printing its
stream events and calling the routes. `CodexCliProvider.over` takes the
guest alone, and its tests play the app-server over the same fake
process, line by line.

**Codex CLI is a server rather than a pipe of messages.**
`CodexCliProvider`'s session is one `codex app-server`, Codex's JSON-RPC
over stdio, holding one ephemeral thread run in
`<cache>/codex-cli/work/<provider-id>/`: Entoli's system prompt is the thread's
`baseInstructions`, each new user message a `turn/start`, and the reply streams
back as item notifications. Entoli's tools are the thread's dynamic tools, so no
MCP bridge is needed: Codex calls one with an `item/tool/call` request carrying
the call's id, and waits for the response. A reply ends where calls arrive.
Those read with the same output are one reply (the hand-out waits one event-loop
turn, `Timer.run`, not a duration), and one that arrives after its reply went
out is the next reply. That is the one rule that also covers code mode, where a
model such as `gpt-6-luna` runs a script in Codex's own `exec` tool and calls
Entoli's tools from inside it, so the model's response never names them. Code
mode cannot be switched off: with its host disabled, those models' `exec` calls
fail.

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

**Copilot CLI and Antigravity CLI are driven over ACP.** Neither GitHub nor
Google lets a third party call the plan's models by API, so both programs
are run the way an editor runs them, as an Agent Client Protocol agent on
stdio (`copilot --acp --stdio`, `agy acp`). `AcpProvider` (`providers/acp.dart`)
is what they share, `AcpSession` the session: `initialize` with no file
system or terminal of Entoli's, `session/new` in the provider's work folder
with Entoli's tools as an HTTP MCP server (the same `McpToolBridge` Claude CLI
reaches, its headers as ACP's list of name and value), the system text as the
session's `systemPrompt` where the agent takes one (override where it offers
that, else append) and in front of the first prompt where it does not, then
the model by the `model` config option or the older `session/set_model`, a
model it does not offer failing the session with the list it does. Each new
user turn is a `session/prompt`; text and thought chunks stream as they come,
`usage_update`'s `used` is the reply's input. A reply ends where the agent
calls Entoli's tools through the bridge: calls read together are one reply
(`Timer.run`, as Codex's), the bridge holds each, and the next step's results
answer them; the prompt's response ends the last reply, by its `stopReason`.
A permission the agent asks for is for a tool of its own and is refused
(`reject_once`); any other request is answered with an error.

Neither has a status command, so `signedIn` opens a session and an
`auth_required` (-32000) is signed out; `signOut` is ACP's `logout` where the
agent advertises it, and otherwise the provider's folders forgotten.
Copilot's own tools are held off by its flags — `--deny-tool` for shell,
write, url and memory, `--disable-builtin-mcps`, `--no-custom-instructions` —
and Entoli's server let through by `--allow-tool=entoli`; its home is
`COPILOT_HOME`, the model also `COPILOT_MODEL`, the effort `--effort`, and it
signs in by `copilot login --web-flow`, whose page calls back to a loopback
port. Its release is GitHub's: one tarball (a zip on Windows) holding the one
program, its SHA-256 the asset's `digest`. Antigravity names no variable for
its home, so `HOME` (and `USERPROFILE`) is moved to the provider's data folder,
and its permissions are by file: `prepare` writes `toolPermission` and an
allow of `mcp(entoli/*)` into `.gemini/antigravity-cli/settings.json` there,
keeping what else the file says. It signs in by `agy acp --login`. Its release
is the manifest its own installer reads, per platform, naming the archive and
its SHA-512 (`CliChecksum.sha512`); the tarball holds `antigravity` beside
other files, taken out by name (`TarGzProgram(member:)`). The models each
lists are what the plans offered when this was written; only Gemini 4 Neon's
window is published (512k), so the rest are taken as 200k, and Copilot's as
the 128k it serves. Nothing here has run against either program: the shapes
are the ACP spec's and the programs' docs'.
