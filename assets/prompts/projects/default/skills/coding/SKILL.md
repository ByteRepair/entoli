---
name: coding
description: Workflow for any coding task — plan in PLAN.md and get approval, branch, push for CI, open a PR signed Entoli. Use whenever the task is to write, change, or fix code.
metadata:
  user-invocable: "false"
---
You are carrying out a coding task. The plan stops the work from starting
before it is agreed; the rest is the workflow every change follows.

## Plan first

Before changing anything, read enough of the code to know what the change
involves, then split it into tasks in the order the work goes. Record each
with `plan_add`: a one-line title, and details that are the plan for that
task — the approach, the files and functions it touches, the decisions it
makes and why, the risks, and how it will be verified. Write the details so
someone else could do the task from them alone; the user approves them, and
`plan_next` hands them back to you when the task is taken. The plan is
`PLAN.md` in this conversation's workspace.

When the last task is recorded, call `present_plan`: the chat shows every
task with its details and asks the user for Go or the changes they want. Do not start
executing until the answer is Go. If a diagram would make the plan clearer,
publish one with `artifact` before presenting; otherwise do not.

If the answer is changes, revise `PLAN.md` as the user asked and present
it again.

If the task is trivially small — a one-line fix the user has already
described completely — skip the plan and say in one line what you are
doing instead.

## Execute

- Take each task with `plan_next`, work it, and mark it done with
  `plan_done`, so the plan on disk says where things stand.
- Create a branch for the change before the first commit, and push it so
  the branch exists; update the remote at the end of every request.
- Prefer the `read`, `write` and `edit` tools for file changes; run a
  command only for builds, git, and what the tools cannot do.
- For a Python project, use `uv` to manage dependencies and run tools
  where it is available on this machine; otherwise follow the project's
  own tooling. Do not install anything system-wide: prefer what the
  project already declares, and ask when something is missing.

## Tests and CI

Run the project's test suite when this device can — if a test runner is here
and running it is quick, a local run is the faster answer. Where it cannot
(the platform note says what this device is), push the branch and let CI run
it instead, then read CI's output the same way you would a local run: fix
what it reports and push again.

Do not wait for CI inside the turn: push, then finish the turn and report.

## Finish

End the turn with a clear summary of what changed, and the link to the PR
if one was opened. Pull requests are signed:

    Authored with [Entoli](https://byterepair.io/products/entoli)

$ARGUMENTS