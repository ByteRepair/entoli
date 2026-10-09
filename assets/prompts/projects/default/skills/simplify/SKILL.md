---
name: simplify
description: Cleans up the changed code — reuse, simplification, efficiency, and depth of fix — and applies the fixes it agrees with. Quality only; for correctness bugs use /code-review.
metadata:
  argument-hint: "[instructions]"
---
User instructions: $ARGUMENTS

Improve the quality of the changed code. Review it for reuse, simplification,
efficiency, and depth of fix, then apply the fixes you agree with. This is not
a bug hunt — a correctness pass is `/code-review`'s job, and anything found
here must leave behavior exactly as it is.

## Step 1 — Set the scope

Read the diff under review with `git diff @{upstream}...HEAD` (`main...HEAD`,
or `HEAD~1` when there is no upstream). Where there are uncommitted changes,
or the range diff came back empty, read `git diff HEAD` as well: a cleanup
pass often runs before the commit. If the user's instructions name a PR
number, a branch, or a file path, review that instead. What you have read is
the scope; do not wander past it.

## Step 2 — Four reviewers, in parallel

Send four `task` calls in one message so they run side by side. Each call runs
under `general` and carries the diff and one of the angles below. The prompt
is the worker's whole task, so spell the contract out in each: read-only —
change nothing, report only — and answer with its findings as its final text,
each finding giving `file`, `line`, a one-line summary, the concrete cost
(what is duplicated, wasted, or harder to maintain), and the fix it proposes.

Where `task` is not offered — a turn with no sub-agents — work the four angles
yourself, in order, and say in the summary that they ran inline rather than as
a fan-out.

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

### Depth of fix
Point at changes made at the wrong level: a special case bolted onto shared
machinery instead of the mechanism beneath it being generalized, a patch that
will need its own patch later. Say what the deeper change is.

## Step 3 — Judge and apply

When all four are back, fold together findings that name the same line or
mechanism. Decide each one yourself: apply the fixes you agree with, and
leave — noting, not arguing with — any whose fix would change behavior the
user asked for, reach far outside the reviewed diff, or that you take to be a
false positive.

Close with a short account of what changed and what was left, or a line
saying the code was already clean.