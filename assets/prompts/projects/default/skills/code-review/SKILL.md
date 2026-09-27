---
name: code-review
description: Reviews the changed code for correctness bugs and cleanup, verifies each finding, then applies the fixes. Bugs outrank cleanup when the two compete.
metadata:
  argument-hint: "[instructions]"
---
User instructions: $ARGUMENTS

Review the changed code for correctness bugs and for cleanup it should have
done, then fix what the review confirms. A bug and a cleanup finding compete
for room, the bug wins.

## Step 1 — Set the scope

Read the diff under review with `git diff @{upstream}...HEAD` (`main...HEAD`,
or `HEAD~1` when there is no upstream). Where there are uncommitted changes,
or the range diff came back empty, read `git diff HEAD` as well: a review
often runs before the commit. If the user's instructions name a PR number, a
branch, or a file path, review that instead. What you have read is the scope.

## Step 2 — Nine finders, in parallel

Send nine `task` calls in one message so they run side by side. Each runs
under `general` and carries the diff and one of the angles below. The prompt
is the worker's whole task, so spell the contract out in each: read-only —
change nothing, report only — and answer with its candidates as its final
text, each candidate giving `file`, `line`, a one-line summary, and a concrete
`failure_scenario`: the inputs or state that make the line misbehave, and what
goes wrong as a result.

Surface what you half-believe: a finder that quietly drops the candidates it
is unsure of is the single biggest source of missed bugs, and the verify step
below exists to judge them. Where `task` is not offered — a turn with no
sub-agents — work the nine angles yourself, in order, and say in the summary
that they ran inline rather than as a fan-out.

Five of the angles hunt for bugs.

### A — the diff, line by line
Read every hunk, then read the function around each hunk: bugs on unchanged
lines of a touched function are in scope, because the change re-exposes or
fails to fix them. For each line ask what input, state, timing, or platform
makes it wrong. Wrong or inverted conditions, off-by-one, dereferencing what
can be absent, a missing `await`, a zero treated as absent, the wrong variable
in a copy-paste, an error swallowed by a catch, regex metacharacters left
unescaped.

### B — what was removed
For each line the diff deletes or replaces, say what behavior or invariant it
enforced, then look in the new code for where that behavior is re-established.
Nowhere to find it is a candidate: the dropped guard, the error path that no
longer runs, the check that got looser, the deleted test that was still
catching something real.

### C — the callers
For each function the diff changes, search for its callers and ask what the
change does to each: a new precondition unmet, a return shape that moved, a
new exception nobody catches, an ordering that no longer holds. Then the
callees: another change in the same diff could make a call unsafe from the
other end.

### D — the language's traps
Sweep the diff for the classic mistakes of the language it is written in: for
Dart, an unawaited future, a late initialiser read too early, a mutable default
built once, an `==` that should be `identical`, an overridden `hashCode` that
forgot `==`, a `Future` consumed twice. Whatever the language, name each
instance the diff introduces.

### E — the wrappers
Where the diff adds or touches a type that stands in front of another — a
cache, a proxy, an adapter, a decorator — check that every method reaches the
thing behind it and not back through a registry, session, or global. A caching
provider whose `delegate` field resolves ids through the session instead of
the delegate re-enters the cache or recurses. Check also that the wrapper
forwards everything its callers actually use.

Four hunt for cleanup, and their candidates take the same shape — in
`failure_scenario`, the concrete cost (what is duplicated, wasted, harder to
maintain) instead of a crash.

### Reuse
Point at new code that rebuilds something the codebase already has. Search
shared and utility modules, and the files next to the change, for the thing
that exists; name the helper the new code should call instead.

### Simplification
Point at complexity the diff does not need: state that is redundant or can be
derived, copies of existing logic with small variations, nesting that would
flatten, code the change left with nothing left to do. Say what the simpler
form is.

### Efficiency
Point at work the diff wastes: the same value computed twice, I/O repeated
where one read would do, independent operations awaited in a row, blocking
work put on a startup or hot path. Also point at long-lived objects that hold
onto a closure or captured environment — the whole enclosing scope stays alive
for the object's lifetime, and a large captured value becomes a leak; a class
or struct holding the few fields it needs is the cheaper shape. Say what the
cheaper alternative is.

### Conventions (AGENTS.md)
Read the instruction files that govern the changed code: the user's global
instructions file beside `settings.json` in the data directory, the
repository-root `AGENTS.md`, and any `AGENTS.md` in a directory that contains
changed files — a directory's file speaks for the files under it, nothing
else. Then flag only what the diff breaks outright: a rule you can quote, at
a line you can name. No style preferences, no reading between the rules. Cite
the file and quote the rule in the finding. Where no instruction file applies,
this angle returns nothing.

## Step 3 — One vote per candidate

Fold together candidates that name the same line or mechanism, keeping the one
with the most concrete failure story. Send one `task` call per remaining
candidate — again all in one message — giving it the diff, the relevant files,
and the candidate, and asking for exactly one verdict:

- **CONFIRMED** — it can name the inputs or state that trigger the defect and
  the wrong output or crash that follows. The line quoted.
- **PLAUSIBLE** — the mechanism is real but the trigger is uncertain (timing,
  environment, configuration). What would confirm it, stated.
- **REFUTED** — the reading is factually wrong, or a guard elsewhere already
  handles it. The line that proves it, quoted.

Keep CONFIRMED and PLAUSIBLE; drop REFUTED.

A realistic state is not grounds for refutation. Races, absent values on rare
but reachable paths — an error handler, a cold cache, a missing optional field
— a zero read as absent, an off-by-one at a boundary nothing excludes, a retry
storm or a partial failure, an allowlist that lost an anchor: these are
PLAUSIBLE. Refute only from the code: the reading contradicts a line (quote
it), the type system or a constant makes it impossible (show it), this diff
already handles it (cite the guard), or it is pure style with no observable
effect.

## Step 4 — Sweep for what the angles missed

Run one more finder — a `task` call under `general` — as a fresh reviewer
holding the verified list. Its only job is gaps: re-read the diff and the
functions around it for defects nobody listed, and re-derive none of what is
there. What the first pass tends to miss is the focus: code that moved and
left a guard behind, second-tier traps (a default argument evaluated once at
definition, `hash()` built from mutable state, a lock given up early, a
predicate with a side effect), test setup and teardown that stopped
mirroring each other, configuration defaults that flipped. Up to eight new
candidates; an empty answer when there are none — never padding.

Run these new candidates through Step 3's vote as well before keeping any.

## Step 5 — Judge and apply

Decide each verified finding yourself: apply the fixes you agree with, and
leave — noting, not arguing with — any whose fix would change behavior the
user asked for, reach far outside the reviewed diff, or that you take to be a
false positive.

Close with a short account of what changed and what was left, or a line saying
the code was already clean.