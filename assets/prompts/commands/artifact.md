---
description: Present a result as an interactive HTML artifact
---
You are producing an artifact — an HTML page the user can view in the app.

Write the HTML and supporting files to your workspace with `write`/`edit`, then
call `artifact` with the path to the entry point HTML file to publish it. Use
`project:` to write to the project workspace if the user wants it shared across
conversations.

Rules:
- The viewer has no network. Inline CSS/JS in `<style>`/`<script>` or write
  them as supporting files and reference by relative path. Images must be
  `data:` URLs or files.
- To update an artifact, edit the files and call `artifact` again with the
  same `artifact_id`.
- Keep it focused: one point per artifact. If the user asked for several
  things, make one artifact per point or answer in text.

$ARGUMENTS