---
name: byte-repair-spec
description: Write or revise a Byte Repair project's spec.md, the specification its ESBMC contracts are derived from. Use first in a Byte Repair task, before any code or contract is written, and again when a counterexample shows the spec is wrong.
---

This turns a request for C code into `<project>/spec.md`. You write the spec
yourself, in this conversation, so you can ask the user as you go; no code,
contracts or harnesses come out of this step.

## Before writing

If the project already has a `spec.md`, you are revising it: read it first
and keep what the request does not change. If `src/` exists, read it to see
what is there, but specify what the code should do, not what it does.

Where the request leaves something open that would change a Requires or
Ensures line, ask the user with `ask_user`, all such questions in one call,
before writing. Anything smaller, pick the reading a careful engineer would
and write it under Assumptions.

## Decomposition

Split the work into small functions with one job each. The aim is functions
ESBMC can verify: a cyclomatic complexity under 10, no nested loops, inputs of
bounded size. Keep parsing, arithmetic and buffer handling in such functions,
and push I/O, allocation-heavy setup and anything with nested loops into thin
functions around them. Mark each function as core (to be verified) or shell
(not verified, and why).

## What spec.md holds

Use these sections, in this order:

    # <project>

    ## Purpose
    One paragraph: what the code is for.

    ## Assumptions
    Each choice you made where the request was silent.

    ## Bounds
    The fixed sizes verification will use: maximum string and buffer lengths,
    maximum element counts, loop limits. Small, such as 16 bytes or 8 elements.

    ## Functions
    For each function, in call order:

    ### <name>
    - Signature: `int parse_int(const char *s, size_t len, int *out)`
    - Kind: core, or shell (and why it will not be verified)
    - Requires: each precondition, one per line, in plain words with the exact
      condition, such as "`s` points to `len` readable bytes", "`len <= 16`".
    - Ensures: each postcondition, one per line, for every outcome including
      errors, such as "returns 0 and writes nothing to `*out` when `s` holds a
      non-digit".
    - Writes: what it may modify, or nothing.

    ## Open questions
    Questions the user has not answered yet, none of them blocking.

Write conditions precisely enough to become `__ESBMC_requires` and
`__ESBMC_ensures` statements: name the parameters, say what happens at the
boundaries (empty input, maximum length, overflow), and give the result for
every error case. A postcondition that only restates the code ("returns the
result of the loop") is no use; say what the result means.

## Done when

- Every function has a Kind, and every core one has Requires, Ensures and
  Writes lines.
- Every error case has a stated result.
- Every size a contract will need is in Bounds.
- No blocking question is left unasked.
