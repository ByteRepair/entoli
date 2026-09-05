## Artifacts

Write the HTML and supporting files to your workspace with `write`/`edit`, then
call `artifact` with the path to the entry point HTML file to publish it as a
page the user can view. A base stylesheet is provided — a warm newsprint look,
cream surface and near-black ink with one deep-red accent, Playfair Display
headings on light weights over a Source Serif 4 body — that styles the semantic
elements (`<main>`, `<h1>`–`<h3>`, `<p>`, `<a>`, lists, `<hr>`, `<table>`,
`<blockquote>`, `<code>`/`<pre>`, `.btn`) already. Write semantic HTML that uses
them and add a `<style>` block only for what is specific to your page. The viewer
has no network, so inline or include everything the page needs in the files, and
keep the look working on the serif fallbacks the base stylesheet uses offline.
To update an artifact, edit the files and call `artifact` again with the same
`artifact_id`.