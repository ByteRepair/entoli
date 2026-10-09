---
name: refactor
description: Audits a codebase — or one subtree of it — for architectural waste: single-consumer abstractions, dead definitions, layers of indirection nobody needs, extension hooks nobody exercises, and one concept built differently in different files. Reports only; nothing is edited.
metadata:
  argument-hint: "[path] [exemption note]"
---
Audit the codebase for architectural waste: abstractions with one consumer,
definitions nothing reaches, indirection that adds nothing, extensibility
hooks nobody exercises, and the same concept implemented differently in
different files. This is not a cleanup pass over a recent change — the whole
repository is in play, or the subtree you are given, including code the latest
change never touched.

**The rule underneath.** An abstraction layer earns its place with multiple
consumers, or with a caller who asked for it. Code with one consumer can be
inlined into it. A shared location is justified by cross-file use, not by the
possibility of reuse one day. The rule reaches every language in scope — CSS
rules, exported functions, types, components, configuration keys — not only
code.

**This audit reports and does not edit.** What it surfaces — relocating code,
inlining abstractions, deleting layers — is architectural, and applying it
blindly is a risk the user takes. They decide what to act on.

## Step 1 — Fix the scope

Read the arguments: a leading token naming an existing path scopes the audit
to that subtree; any free text after it is an **exemption note**, and
abstractions it names ("leave the ORM layer alone", "the shortcode API stays")
are treated as deliberately justified and passed over by the co-location and
abstraction angles. Neither, and the whole repository is in scope with no
exemptions.

Work out which languages and frameworks the scope holds, and aim each angle's
searches at that language: CSS classes against markup, exported symbols
against imports, configuration keys against readers, component props against
uses. Say the scope and any exemption note before the angles start.

## Step 2 — Five auditors, in parallel

Send five `task` calls in one message so they run side by side. Each runs
under `general` and carries the scope, the exemption note, and one of the
angles below. The prompt is the worker's whole task, so spell the contract
out in each: read-only — change nothing, report only — and answer with its
findings as its final text, each finding giving `file`, `line`, a summary,
the consumer count where one is claimed, and a suggested action — inline, move
file-local, move to shared, delete, or reconcile.

Where `task` is not offered — a turn with no sub-agents — work the five angles
yourself, in order, and say in the report that they ran inline rather than as
a fan-out.

### Where things live
For every abstraction in scope — a function, class, CSS rule, component, type,
exported symbol, configuration key — search the whole codebase for its
consumers, and classify: one consumer, inline it into that consumer; several
consumers in one file, make it file-local (a private helper, a file-scoped
static, a `<style>` block); consumers across files, put it somewhere shared.
Then flag the mismatches: an abstraction in a shared location with a single
consumer, one in a single-use location with consumers across files, and one
whose only consumer is its own definition. Name the consumers you found; the
classification is only as good as the search behind it.

### Dead code
A whole-codebase sweep, not a look at recent work: exports nothing imports,
functions, classes and types nothing references, CSS classes no element uses,
configuration keys nothing reads, files nothing includes, branches nothing
reaches, private members nothing uses. Before flagging a symbol, search for
every plausible spelling and alias of it, and say you did.

### Layers that do nothing
Indirection with one implementation behind it: a wrapper, adapter or decorator
that adds no behavior, an interface with one implementor, an abstract base for
a single concrete class, a generic helper parameterized for one call site, a
factory that only ever builds one type. Name the call sites that prove the
layer is dead weight. The exemption note passes over anything it covers.

### Extension points nobody uses
Configuration hooks, parameters, options and plugin points without a caller:
parameters that only ever take their default, flags always set to the same
value, optional callbacks nobody provides, generic type parameters always
bound to the same type, `--keep`-style flags with one caller. Name every call
site to prove the hook is dead. The exemption note passes over anything it
covers.

### One concept, two implementations
The same idea built differently in different files: a component rendered with
different wrappers (one bare, one wrapped in a `<p>`, one centered, one not),
a utility defined twice with the variation unexplained, the same role under
different names, the same CSS rule in two files. Flag where the divergence
changes something observable — spacing, color, behavior — not pure style, and
name both files and the difference between them.

## Step 3 — Verify the counts

Fold together findings that name the same definition. Then re-search the
codebase for every finding that claimed a consumer count, and kill the ones
the search does not support — a caller missed, a comment read as a consumer, a
string match read as a reference. Drop anything the exemption note covers.
Rank what is left by impact: dead code and single-consumer abstractions
first, cross-file consistency next, the merely stylistic last.

## Step 4 — Report

Write the report grouped by angle, and change nothing. Each finding names its
`file` and `line`, the concrete cost (what is dead, duplicated, or harder to
maintain), the consumer count where one is claimed, and the suggested action.
Leave an empty category out rather than writing "no findings" for it. Close
with one line:

```
audit done: N findings - A dead code · B single-consumer abstractions · C unnecessary layers · D dead extensibility · E consistency divergences
```

Where the audit found nothing at all, that line reads:
`audit done: the codebase is clean.`