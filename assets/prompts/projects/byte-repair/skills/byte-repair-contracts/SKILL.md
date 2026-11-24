---
name: byte-repair-contracts
description: Write a Byte Repair project's ESBMC contracts from its spec.md, as function stubs with empty bodies, or revise a contract when verification shows it is wrong. Use after the spec and before any body is written, and for every later contract change.
---

This writes the contracts in `<project>/src/` from `spec.md`. Contracts are
written before the code because contracts written after tend to describe
what the code happens to do. You will write the bodies next, in the same
conversation, so the rules under Changing a contract are what keep the
contracts honest: follow them every time.

## Contracts

Contracts are statements at the start of the function body, not on its
signature. The constructs, which need no header:

- `__ESBMC_requires(cond)`, `__ESBMC_ensures(cond)`: pre- and postconditions.
- `__ESBMC_return_value`: the return value, used in `ensures`.
- `__ESBMC_old(expr)`: the value of `expr` on entry, used in `ensures`.
- `__ESBMC_assigns(...)`: what the function may write. `__ESBMC_assigns()` for
  nothing, `__ESBMC_assigns(*out)` for a whole object, `__ESBMC_assigns(p[i])`
  for one element. There is no range form.
- `__ESBMC_is_fresh(p, n)`: in `requires`, says `p` points to `n` valid bytes
  that no other pointer shares. State it for every pointer the function
  dereferences.

That is all the syntax you need. Do not search the web or probe ESBMC for it.
Write files containing `__ESBMC_` text with the `write` or `edit` tool, not a
heredoc in `bash`: the command safety check wrongly flags that text.

## Writing the stubs

Group the functions into files as the spec's decomposition suggests, with a
header for whatever one file calls in another. Each stub is the signature, the
contract statements, a `/* TODO: implement */` line, and the shortest return
that compiles:

    int parse_int(const char *s, size_t len, int *out)
    {
        __ESBMC_requires(len <= 16);
        __ESBMC_requires(__ESBMC_is_fresh(s, len));
        __ESBMC_requires(__ESBMC_is_fresh(out, sizeof(int)));
        __ESBMC_assigns(*out);
        __ESBMC_ensures(__ESBMC_return_value == 0 || __ESBMC_return_value == -1);
        /* TODO: implement */
        return 0;
    }

Write shell functions as plain stubs with no contract. Write every stub before
any body.

Translate every Requires, Ensures and Writes line of the spec, using the
spec's Bounds for every size. An outcome the spec gives per case becomes an
implication: `__ESBMC_ensures(!(cond) || (result))`. Where a line cannot be
expressed with these constructs, such as a property of every element of a
buffer, keep the part you can express and note the rest for the report. Where
a line is contradictory or too vague to translate, fix the spec with the
`byte-repair-spec` skill first.

## Changing a contract

Once a body exists, a contract statement changes only when the spec supports
the change:

- A counterexample shows the contract does not say what a spec line says:
  change the statement to match that line.
- The spec line itself is wrong: change it with `byte-repair-spec` first,
  then the statement.
- The code cannot meet the contract: that is a code fault. Fix the body, not
  the contract.

A new helper split out of a body gets its contract from the spec before its
body is written; add its lines to the spec if they are not there. Keep a list
of every statement changed in the run, each with the spec line behind it; it
goes in the report's notes.

## Checking a weakened contract

A change that lets more inputs or outcomes through, such as a dropped or
looser `ensures` or a stronger `requires`, is the change the code's author is
most tempted to make. Before verifying it, check it with a fresh reader who
does not see the code: one `task` call under `explore`, with this brief, the
project and the change substituted in:

> Check a change to an ESBMC contract against its specification. Read
> `<project>/spec.md` only: do not open `src/` or `harness/`, since the
> question is what the spec asks for, not what the code does. The function is
> `<function>`. The old statements were `<old>`; the new ones are `<new>`. The
> counterexample that prompted the change was `<counterexample>`. For each
> changed statement, quote the spec line it must express and answer: does the
> new statement say what that line says, no less? Reply with one line per
> statement: `OK`, or `WEAKER: <what the spec asks that it no longer checks>`.

For a WEAKER line, restore the statement and fix the code instead, or, if the
spec is what is wrong, ask the user before changing it.

## Done when

- Every Requires, Ensures and Writes line of every core function is a
  contract statement, or is listed as not expressible with the reason.
- Every pointer a function dereferences has an `__ESBMC_is_fresh`.
- Every changed statement names the spec line behind it.
