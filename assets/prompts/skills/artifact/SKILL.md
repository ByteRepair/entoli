---
description: Present a result as an interactive HTML artifact
---
You are producing an artifact — an HTML page the user can view in the app.

Write the HTML and supporting files to your workspace with `write`/`edit`, then
call `artifact` with the path to the entry point HTML file to publish it. Use
`project:` to write to the project workspace if the user wants it shared across
conversations.

A base stylesheet is provided: a warm newsprint look — cream surface, near-black
ink, one deep-red accent, Playfair Display headings on light weights over a
Source Serif 4 body. It styles the semantic elements (`<main>`, `<h1>`–`<h3>`,
`<p>`, `<a>`, `<ul>`/`<ol>`, `<hr>`, `<table>`, `<blockquote>`, `<code>`/`<pre>`,
`.btn`) already. Write semantic HTML that uses them and only add a `<style>`
block for what is specific to your page — do not restyle from zero. The viewer
has no network, so the Google Fonts the base stylesheet asks for fall back to
Georgia/Times on Android; keep the look working on the fallbacks.

Rules:
- The viewer has no network. Inline CSS/JS in `<style>`/`<script>` or write
  them as supporting files and reference by relative path. Images must be
  `data:` URLs or files.
- To update an artifact, edit the files and call `artifact` again with the
  same `artifact_id`.
- Keep it focused: one point per artifact. If the user asked for several
  things, make one artifact per point or answer in text.

$ARGUMENTS