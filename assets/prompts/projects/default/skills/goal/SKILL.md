---
name: goal
description: Set a goal the agent keeps working toward, across stops, until a reviewer finds it met; nothing in this note is sent to a model
metadata:
  invocation: callback
  argument-hint: "[objective] | pause | resume | clear"
---
`/goal <objective>` sets a goal for this chat and starts working on it. The
agent is asked to achieve it fully and finish by showing the evidence.

Each time the agent stops — a reply with no tool call — a reviewer reads the
conversation and decides whether the goal is met. The agent's own word that it
is done does not count: the reviewer looks for evidence, such as a command's
output or a check that passed. If the goal is not met yet, the reviewer's
reason goes back to the agent as a note and it carries on. If the goal needs
you — a decision, access, or information only you have — the reviewer marks it
blocked and the agent stops.

The reviewer is the classifier model set under Settings, or the chat's own
model where none is set. Write the objective so it can be checked: "the tests
in `test/` pass and `flutter analyze` is clean" is better than "fix the
tests".

- `/goal` alone says what the goal is and where it stands.
- `/goal pause` stops the reviews; the goal is kept. It works while a turn is
  running, and takes effect at the agent's next stop.
- `/goal resume` turns the reviews back on and carries on with the work.
- `/goal clear` removes the goal. `stop`, `off`, `reset`, `none` and `cancel`
  do the same.

A goal pauses itself after 50 rounds of being sent back, or when the agent
stops three times in a row without doing anything in between. One goal per
chat: setting another replaces it. The pill above the composer shows the goal
and has its pause, resume and clear buttons.
