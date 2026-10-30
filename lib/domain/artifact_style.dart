/// The base stylesheet the artifact viewer injects before the model's own
/// HTML. Adapted from the Byte Repair landing page: a warm newsprint cream
/// surface, near-black ink, a single deep-red accent, Playfair Display
/// headings on light weights over a Source Serif 4 body. Dropped from the
/// original are the homepage/news/article-specific classes the agent will
/// never produce — what is left is element-level styling for the semantic
/// HTML (`<main>`, `<h1>`–`<h3>`, `<p>`, `<a>`, lists, `<hr>`, tables, code,
/// `<blockquote>`) the prompt tells it to write.
///
/// The viewer has no network on Android, so the Google Fonts `<link>` is a
/// no-op there and the font stacks fall back to `Georgia` / `Times New Roman`
/// / serif, which keeps the newspaper character. On desktop, where a browser
/// is online, the `<link>` loads and the look is the real one.
const _baseMarker = "<!-- entoli-base-css -->";

const _fontsHead = """
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@200;300;400;700;900&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,600;0,8..60,700;1,8..60,400&display=swap" rel="stylesheet">""";

const _baseCss = """
$_baseMarker
<style>
:root {
  --bg: #f5f1e8;
  --bg-alt: #ede8db;
  --ink: #1a1a1a;
  --ink-soft: #4a4a4a;
  --ink-faint: #8a8a8a;
  --rule: #1a1a1a;
  --rule-soft: #c9c2b3;
  --accent: #8b1a1a;
  --link: #1a1a1a;
  --link-hover: #8b1a1a;
  --font-display: "Playfair Display", "Didot", "Times New Roman", Georgia, serif;
  --font-body: "Source Serif 4", "Georgia", "Times New Roman", serif;
  --font-mono: "Courier New", monospace;
  --max-width: 1100px;
  --gutter: 2rem;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

html { font-size: 18px; scroll-behavior: smooth; }

body {
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font-body);
  line-height: 1.65;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}

main,
.container {
  max-width: var(--max-width);
  margin: 0 auto;
  padding: 0 var(--gutter);
}

@media (max-width: 1100px) {
  :root { --gutter: 2.5rem; }
}

a {
  color: var(--link);
  text-decoration: underline;
  text-underline-offset: 2px;
  transition: color 0.15s ease;
}

a:hover { color: var(--link-hover); }

hr {
  border: none;
  border-top: 1px solid var(--rule);
  margin: 3rem 0;
}

hr.double {
  border-top: 3px double var(--rule);
}

h1, h2, h3 {
  font-family: var(--font-display);
  color: var(--ink);
  line-height: 1.05;
}

h1 {
  font-weight: 200;
  font-size: clamp(2.5rem, 6vw, 4.5rem);
  letter-spacing: -0.015em;
  margin-bottom: 1.5rem;
}

h2 {
  font-weight: 300;
  font-size: clamp(2rem, 4vw, 2.75rem);
  letter-spacing: -0.01em;
  margin-bottom: 1.25rem;
  padding-bottom: 0.75rem;
  border-bottom: 1px solid var(--rule);
}

h3 {
  font-weight: 400;
  font-size: 1.5rem;
  letter-spacing: -0.005em;
  margin-top: 2rem;
  margin-bottom: 0.5rem;
}

p { margin-bottom: 1rem; }

ul, ol {
  margin-bottom: 1.5rem;
  padding-left: 1.5rem;
}

li { margin-bottom: 0.4rem; }
li::marker { color: var(--ink-faint); }

ul li { list-style-type: disc; }
ol li { list-style-type: decimal; }

strong { font-weight: 700; }
em { font-style: italic; }

blockquote {
  border-left: 3px solid var(--accent);
  padding-left: 1.5rem;
  margin: 1.5rem 0;
  font-style: italic;
  color: var(--ink-soft);
}

code {
  font-family: var(--font-mono);
  background: var(--bg-alt);
  padding: 0.15rem 0.4rem;
  font-size: 0.9rem;
}

pre {
  background: var(--bg-alt);
  padding: 1.5rem;
  overflow-x: auto;
  margin: 1.5rem 0;
  border: 1px solid var(--rule-soft);
}

pre code {
  background: none;
  padding: 0;
}

table {
  width: 100%;
  border-collapse: collapse;
  margin: 2rem 0;
  font-size: 0.95rem;
  display: block;
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}

th, td {
  padding: 0.85rem 1rem;
  text-align: left;
  border-bottom: 1px solid var(--rule-soft);
}

th {
  font-family: var(--font-display);
  font-weight: 700;
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  border-bottom: 2px solid var(--rule);
}

.btn {
  display: inline-block;
  font-family: var(--font-body);
  font-size: 0.85rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  text-decoration: none;
  color: var(--bg);
  background: var(--ink);
  padding: 0.75rem 2rem;
  border: 1px solid var(--ink);
  transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
  cursor: pointer;
}

.btn:hover {
  background: var(--accent);
  border-color: var(--accent);
}
</style>""";

/// Insert the base stylesheet and Google Fonts link into [html]'s `<head>`.
/// If [html] has no `<head>` (a fragment, or `<!DOCTYPE>` only), one is opened
/// for it. A no-op once the marker is already present, so calling this on an
/// already-injected page does not duplicate the block.
String injectBaseStyles(String html) {
  if (html.contains(_baseMarker)) return html;

  final injection = "$_fontsHead\n$_baseCss";

  final headStart = _headStart.firstMatch(html);
  if (headStart != null) {
    final at = headStart.end;
    return "${html.substring(0, at)}\n$injection${html.substring(at)}";
  }

  final htmlStart = _htmlStart.firstMatch(html);
  if (htmlStart != null) {
    final at = htmlStart.end;
    return "${html.substring(0, at)}\n<head>\n$injection\n</head>${html.substring(at)}";
  }

  final bodyStart = _bodyStart.firstMatch(html);
  if (bodyStart != null) {
    final at = bodyStart.start;
    return "${html.substring(0, at)}<head>\n$injection\n</head>${html.substring(at)}";
  }

  return "<!DOCTYPE html>\n<html>\n<head>\n$injection\n</head>\n<body>\n$html\n</body>\n</html>";
}

final _headStart = RegExp(r"<head[^>]*>", caseSensitive: false);
final _htmlStart = RegExp(r"<html[^>]*>", caseSensitive: false);
final _bodyStart = RegExp(r"<body[^>]*>", caseSensitive: false);