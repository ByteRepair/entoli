# The local shell

## Running the commands

The shell's contract, `bash`, background jobs and the user's `!` are the
core's: see `packages/entoli_core/lib/agent/AGENTS.md`.

What the app is given by the machine it runs on — a shell or none, the
filesystem and where its root is — is resolved in `lib/core/platform/`:
`host.dart` answers each question for this machine (`LocalShell`,
`DuckDuckGoSearch`, and the drivers, stores and channels each OS has), and
`platform.dart` is plain wiring over it, re-exporting what the rest of the app
asks for. The TLS trust a network call verifies under is `lib/core/tls.dart`,
reading the OS's store and falling back to the bundled Mozilla root set where a
Windows machine's own has never been refreshed.

The chat store and the prompt sources used to vary and do not any more — one
filesystem means one of each, built in `platform.dart` itself. What is left
varying is the shell, where the filesystem's root is, `FileHandoff` (see "The
hand-offs" in `packages/entoli_files/lib/AGENTS.md`), and `AssistantLaunch`
(Android's assistant gesture, and a stub that never fires anywhere else — see
"Being the assistant").

`Shell.canRunCommands` is what a machine with no shell changes, and it is not
one failing command — it is the whole loop. With no shell there is nothing to
run, so `bashTool` is dropped from the request and a system prompt with no tool
instructions is used; the turn ends when the model replies with text and no tool
call, the same termination signal the shell path uses.

**What the commands run under is a `ShellDriver`, and which one is resolved
rather than named.** The host driver is the machine's own shell — `bash` then
`sh` off `PATH`, then `/bin/bash`, `/system/bin/sh`, `/bin/sh`, the two places a
shell sits that a `PATH` may not name, a stripped environment and Android, which
has no `/bin` at all. It was `/bin/bash` or `/bin/sh`, which meant a phone was
offered the `bash` tool and then failed every command it ran, one at a time.
Nothing found is a null driver and `canRunCommands: false`, which is the
honest answer: the loop stops offering a tool there is
nothing behind. The other driver is the guest — see "A whole Linux under proot"
in `data/local/` — and `platformDriver` picks between the two per command.
**Android gets the guest or nothing.** Its own shell was offered as "Host"
until the Linux became what everything leans on — package installs, Byte
Repair's setup, the CLI programs — and a turn run on toybox with no `/bin`
only failed further in. With no Linux picked, `platformDriver` is null there,
as iOS's shell is with none installed, `LocalShell.withoutDriver` tells the
model why, and the first-run setup is what installs one.
`LocalShell` runs whichever it is handed, since to it both are a command that
ends in a shell, and that is the whole of what a new driver owes it.

On Windows the host driver wants `bash.exe` or `sh.exe` off `PATH`, skipping
anything under `%SystemRoot%` — WSL's `System32\bash.exe` runs a Linux that
cannot take a Windows path — then Git for Windows' bash, found under
`%ProgramFiles%\Git` or beside the `git.exe` on `PATH`. There is no `setsid`
and no signal there: a stop or a timeout is `taskkill /T /F`, the one way to
take bash's children with it, and the interrupt step is skipped. The AppImage
runtime's `APPIMAGE`, `APPDIR`, `ARGV0` and `OWD` are stripped from every
command's environment; they describe the app, not the machine.

**The shell creates the directory it is told to stand in if it is not there.**
A spawn `workingDirectory` that does not exist fails with an ENOENT that names
neither the directory nor the reason, and the cwds the app hands the shell are
its own laid-out paths that may legitimately be missing: a project workspace
before its first chat — a built-in project's setup runs in one — or one a user
deleted from the Files app. So `_spawnInGroup` makes it before `Process.start`,
in the one place both the one-shot and the persistent paths spawn through.

**The commands run in one shell per chat, and its state is machine state the
conversation builds on.** A fresh subshell per command made a `cd` or an
`export` a private joke: the model moved the shell in one command, and the next
command was back in the workspace having heard nothing. So a chat has one
non-interactive shell — the agent's `bash` and the user's `!` share it, and it
is keyed by the chat's own workspace, which is unique to the chat — and what
one command did to the directory or the environment stands for the next.

Each command crosses as one base64 line on the shell's stdin: the raw script
never touches the wire, so a multi-line command, a quote or a `read` in it
cannot steal the next line of the queue. The dispatcher decodes the line and
evaluates it **in the shell itself** — a subshell would undo the point — and
then prints a sentinel naming the command's exit code and the directory the
shell is now in. The sentinel carries a token unique to the shell's life, so a
command's output cannot forge the end of a run, and the run completes on the
sentinel rather than on the pipe closing. That is the answer to the old
hazard: a child in a session of its own — a daemon started with `setsid`,
anything a `nohup` left behind — holds the pipe open after the shell is gone,
and held it open forever, so a run waited on the pipe was a turn nothing could
finish. The sentinel makes the run end when the command does; what the escaped
child can still delay is the settling of a run whose shell *died*, and that is
bounded by a grace on the process's exit rather than waited on.

Stopping a command is a `SIGINT` to the process group — a Ctrl-C, not a
murder — and a non-interactive shell dies on that signal unless it is told
otherwise, which is load-bearing: the dispatcher traps the interrupt so the
shell waits for the interrupted command to go, reports its 130, and keeps
whatever state it had. A trap on `EXIT` is the other end: a command that runs
`exit` takes the shell down with it, and the trap is what says how it went —
the code and the directory — before the pipe closes. A stop the command
ignores is wedging the shell, and a grace past it kills the group for real,
the shell coming back cold on the next command. A timeout escalates whichever
way: what a non-interactive shell starts in the background ignores the
interrupt, and a timed-out `npm install` that only lost its shell keeps
downloading — so the kill lands the moment the command's own sentinel comes,
the interrupt spent and the grace unable to reach any sooner, or at the end of
the grace where the command never answered at all. The
group is the reason the shell is spawned under `setsid` where that exists —
learned by trying it, not by probing first.

**The command's label is the model's own word for it.** `bash` takes an
optional `description`, five to ten words on what the command does, and the
reply draws it as the row's label in place of "Used tool: bash" — Claude
Code's design: no second model reads the command to name it, so the label
costs nothing. It is the agent's claim about its command and nothing checks
it. It is shown beside the command, never in its place: the approval banner
draws it above the command (`approvalPurpose`), so the user sees the intent
and what will run, and the classifier reads it labelled as the agent's
claim, judging the command and asking where the two disagree. A call without
one, and the user's `!`, keep the tool's name.

**How long a command may run is Claude Code's two minutes and ten.**
`BuiltinOptions.commandTimeout` is what a call naming no `timeout` gets, two
minutes, and `maxCommandTimeout` is the most one may name, ten — Claude Code's
120,000 and 600,000 milliseconds, measured. It was three minutes for both, and
the chat that prompted the change had 25 commands hit it, mostly builds and CI
waits. The user's `!` gets the ten: they typed it and are there to stop it.

A command killed at its timeout keeps what it printed — the session shell's
interrupt and the one-shot kill both hand back the output so far — and
`ShellResult.timedOut` says that is why it stopped. Here Claude Code and this
part ways on purpose: Claude Code moves a timed-out command to the background
and lets it run, reporting `Command did not complete within its 120s timeout
and was moved to the background (ID: …)`. Every Claude Code command is a
process of its own, so stopping waiting is free; here a chat's commands run in
one shell, and a command left running in it is one every later command waits
behind. So it is killed, as before, and `bash` adds to a timed-out result,
where background jobs are offered, that something that long goes in again with
`background: true`. The descriptions say it ahead: `command`'s that the whole
output comes back and is saved past the limit, so `| tail` buys nothing and a
pipeline killed at the timeout loses all `tail` was holding — 14 of that chat's
21 empty timeouts were pipes into `tail` or `head` — and `timeout`'s and
`background`'s that anything that may outlast the timeout is a job.

A command that moved the shell records the directory it left it in, on the
result as a fact, and the projection words the change into a note the model
reads — the note is derived at wording time from the fact the part carries,
not baked into the output, so a reload words what the live turn did and the
output stays what the command printed. It tracks the directory across the
turn's commands and notes a move once it has been told where the shell is
standing; the turn's opening move is un-noted, the model having run the `cd`
itself. The composer's bar watches the same directory live while a `!` command
is being typed, and a tap copies it out.

What a shell is spawned with — its command and environment — is fingerprinted,
and a change respawns the shell cold: a variable added in settings, or a Linux
installed or deleted, reaches the next command rather than the next launch.

**A sandboxed command still moves the chat.** Under the sandbox every
command is a confined subshell of its own (see "Approvals" in
`packages/entoli_core/lib/agent/AGENTS.md`), so it cannot
stand in the session shell — and it used to start in the workspace whatever
the session shell had been moved to, which gave a chat two working
directories, the model told of one and standing in the other half the time.
So `LocalShell` keeps one directory per chat on the host (`standingIn`): a
confined run starts there and ends by printing where it finished after a
marker unique to the run, cut from the output and reported as the result's
`ShellResult.cwd`, the same field the session shell's sentinel fills; the
session shell's sentinel updates the same place; and the session shell `cd`s
to it before a command when a confined run moved the chat since. Exports,
aliases and functions stay each confined run's own, which is what the tool
description says. A restart or a shell that died puts the chat back in the
workspace. A guest keeps none of this: its `pwd` is a guest path and it has
no confined subshell.

Sub-agents run `oneShot` instead: a fresh subshell per command, no state, no
sharing. A fan-out of workers wants concurrency rather than a terminal, and a
shell they all `cd` around is as many races as there are of them. The flag
reaches the shell and the prompt and the tool description together, so the
model is not told a state it cannot keep.

**The output a running command is printing is visible while it prints.** A
`ShellRun` carries an output listener beside its result, and the agent watches
it where a callback is handed to it, reporting each change at
`watchInterval`'s pace — a hundred milliseconds, the last value inside an
interval being the one sent, since what the block shows is the tail as it is
now. What it reports is a tail of the output, newlines kept, never the
sentinel: the dispatcher's marker can arrive split across chunks, so anything
from the last place `\n@@E` could be forming is held out of the live view until
the next chunk proves it was ordinary output. The final result is unchanged —
the whole output, sentinel stripped — and the block on screen is gone the moment
the pair completes, the conversation keeping only the pair. Nothing here is
persisted and a sub-agent's commands are not watched, the callback being null
where the agent is one.
