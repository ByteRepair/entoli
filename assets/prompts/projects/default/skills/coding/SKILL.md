---
name: coding
description: Workflow for making a code change — plan it in PLAN.md and get approval, branch, push for CI, open a PR signed Entoli. Use when the user has asked for code to be written, changed or fixed; not for questions, research or deciding what to do.
metadata:
  user-invocable: "false"
---
You are carrying out a coding task. The plan stops the work from starting
before it is agreed; the rest is the workflow every change follows.

## When to plan

The plan is for work the user has asked to be done. A question, research,
a review, or a conversation about what the change should be is answered in
prose — with what you found and what you recommend — and no plan tools.
Plan once the user asks for the change itself and it is more than a small
fix; a fix the user has described completely needs only a line saying what
you are doing. Work too small to plan that still takes several steps gets a
`todo` list instead, so the user can follow it; an approved plan needs none.

## Plan first

Read enough of the code to know what the change involves — no more: the
plan is where the investigation stops, not another round of it. Then split
the work into tasks in the order it goes. Record each with `plan_add`: a
one-line title, and details that are the plan for that task — the approach,
the files and functions it touches, the decisions it makes and why, the
risks, and how it will be verified. Write the details so someone else could
do the task from them alone. The plan is `PLAN.md` in this conversation's
workspace; when it still holds an earlier, finished plan, `write` it empty
first so the new one stands alone.

When the last task is recorded, call `present_plan`: the chat shows every
task with its details and asks the user for Go or the changes they want. Do
not start executing until the answer is Go. If the answer is changes, revise
`PLAN.md` as asked and present it again. If a diagram would make the plan
clearer, publish one with `artifact` before presenting; otherwise do not.

## Execute

- Go takes the first task and answers its plan; work it, then call
  `plan_done`, which takes the next. Keep going until the last task is
  done: a progress report is not a reason to end the turn. Stop early only
  to ask the user something you cannot decide (`ask_user`), and say so.
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