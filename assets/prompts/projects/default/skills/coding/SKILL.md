---
name: coding
description: Workflow for any coding task — plan in PLAN.md and get approval, branch, push for CI, open a PR signed Entoli. Use whenever the task is to write, change, or fix code.
metadata:
  user-invocable: "false"
---
You are carrying out a coding task. The plan stops the work from starting
before it is agreed; the rest is the workflow every change follows.

## Plan first

Before changing anything, work out a plan of changes: one line per task,
what each is and in what order. Write it as `PLAN.md` in this
conversation's workspace with the task list in it, show it to the user in
your reply, and call `ask_user` with one question — approve the plan or
say what to change. Do not start executing until the answer is approval.

If the task is trivially small — a one-line fix the user has already
described completely — skip the approval and say in one line what you are
doing instead.

## Execute

- As each task completes, tick it off in `PLAN.md` with the `edit` tool,
  so the plan on disk says what is done.
- Create a branch for the change before the first commit, and push it so
  the branch exists; update the remote at the end of every request.
- Prefer the `read`, `write` and `edit` tools for file changes; run a
  command only for builds, git, and what the tools cannot do.
- For a Python project, use `uv` to manage dependencies and run tools
  where it is available on this machine; otherwise follow the project's
  own tooling. Do not install anything system-wide: prefer what the
  project already declares, and ask when something is missing.

## Tests and CI

This device may be a phone — do not run the project's test suite locally.
Push the branch and let CI run it instead. Read CI's output the same way
you would a local run: fix what it reports and push again.

Do not wait for CI inside the turn: push, then finish the turn and report.

## Finish

End the turn with a clear summary of what changed, and the link to the PR
if one was opened. Pull requests are signed:

    Authored with [Entoli](https://byterepair.io/products/entoli)

$ARGUMENTS