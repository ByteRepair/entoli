#!/usr/bin/env python3
"""Record a Byte Repair verification run and render its report.

Reads the results the verifiers wrote, <project>/.entoli/byte-repair/results/
<run>/harness-<function>.json, with what the agent adds as JSON (a file, or -
for stdin), appends the run to the history kept inside the code being
verified, <project>/.entoli/byte-repair/reports/, and writes report.md and
html/index.html beside it. The history travels with
the code, wherever it was put. Prints the Markdown report on stdout. Standard
library only: it runs wherever python3 does.
"""

import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys

STATUSES = ("PASS", "FAIL", "SKIP")
BLAMES = ("code", "contract", "spec")
ROOT_DIR = (".entoli", "byte-repair")
DATA_DIR = ROOT_DIR + ("reports",)
RESULTS_DIR = ROOT_DIR + ("results",)
RUN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# ESBMC's output for one function can run to megabytes; the end of it, where
# the counterexample and the verdict are, is what a reader wants.
LOG_LIMIT = 20000
METRIC_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$")
FUNCTIONS_METRIC = "Functions verified"
FOOTER = "Generated with Entoli"
# Series colours after the first, which is the stylesheet's accent. Dark
# enough to read on the cream surface the base stylesheet sets.
SERIES_COLOURS = ("var(--accent, #8b1a1a)", "#1f5f8b", "#3f7a3a", "#8a6a12", "#5b3f8a")


class InputError(Exception):
    pass


def fail(message):
    print(f"report.py: {message}", file=sys.stderr)
    sys.exit(1)


def read_run(source):
    try:
        text = sys.stdin.read() if source == "-" else open(source, encoding="utf-8").read()
    except OSError as e:
        raise InputError(f"cannot read {source}: {e.strerror}")
    try:
        run = json.loads(text)
    except json.JSONDecodeError as e:
        raise InputError(f"input is not JSON: {e}")
    if not isinstance(run, dict):
        raise InputError("input must be a JSON object")
    return run


def check_result(r, where):
    """One function's result, as a verifier wrote it or the agent gave it."""
    if not isinstance(r, dict):
        raise InputError(f"{where} must be an object")
    fn = r.get("function")
    if not isinstance(fn, str) or not fn.strip():
        raise InputError(f'{where}: "function" is required')
    status = str(r.get("status", "")).upper()
    if status not in STATUSES:
        raise InputError(f'{where} ({fn}): "status" must be one of {", ".join(STATUSES)}')
    blame = r.get("blame")
    if status == "FAIL":
        if blame not in BLAMES:
            raise InputError(f'{where} ({fn}): a FAIL needs "blame", one of {", ".join(BLAMES)}')
    elif blame is not None:
        raise InputError(f'{where} ({fn}): "blame" is only for a FAIL')
    result = {"function": fn, "status": status, "blame": blame}
    for key in ("detail", "log", "bounds"):
        value = r.get(key, "")
        if not isinstance(value, str):
            raise InputError(f'{where} ({fn}): "{key}" must be a string')
        result[key] = value.strip()
    if status != "PASS" and not result["detail"]:
        raise InputError(f'{where} ({fn}): a {status} needs a "detail" saying why')
    result["log"] = cut_log(result["log"])
    return result


def cut_log(log):
    return log if len(log) <= LOG_LIMIT else "[earlier output cut]\n" + log[-LOG_LIMIT:]


def read_results(folder):
    """What the verifiers wrote, one harness-<function>.json each. A fix
    round re-verifies into the same folder, so each file is that function's
    latest result."""
    try:
        names = sorted(n for n in os.listdir(folder) if n.startswith("harness-") and n.endswith(".json"))
    except OSError:
        raise InputError(f"no verifier results at {folder}; --run must be the id the verifiers were given")
    found = {}
    for name in names:
        try:
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise InputError(f"{name} is not readable JSON ({e}); run its verifier again or correct it")
        r = check_result(data, name)
        if r["function"] in found:
            raise InputError(f"{name}: {r['function']} has a result in another file too")
        found[r["function"]] = r
    return found


def merge_results(found, given, previous, previous_number):
    """The run's results: what the verifiers found, what the agent adds, and
    for every other function its result in the previous run, marked as
    carried. The agent may re-blame a verifier's FAIL or reword its detail,
    but a status is ESBMC's and is never overridden."""
    merged = dict(found)
    if not isinstance(given, list):
        raise InputError('"results" must be a list')
    seen = set()
    for i, r in enumerate(given):
        where = f"results[{i}]"
        fn = r.get("function") if isinstance(r, dict) else None
        if fn in seen:
            raise InputError(f"{where}: {fn} is listed twice")
        seen.add(fn)
        if fn in found:
            verified = found[fn]
            status = str(r.get("status", verified["status"])).upper()
            if status != verified["status"]:
                raise InputError(f"{where} ({fn}): the verifier found {verified['status']}; "
                                 f"a status cannot be overridden, only blame and detail")
            r = {**verified, **{k: v for k, v in r.items() if k in ("blame", "detail")}}
        merged[fn] = check_result(r, where)
    for fn, r in previous.items():
        if fn not in merged:
            # The verdict alone, and the run it was verified in, which a
            # second carry keeps: its spec, harness and log stay in that run
            # rather than being copied into every run after it.
            merged[fn] = {k: r.get(k) for k in ("function", "status", "blame", "detail", "bounds")}
            merged[fn]["carried"] = r.get("carried") or previous_number
    if not merged:
        raise InputError("no results: the run's folder is empty and none were given")
    order = [fn for fn in previous if fn in merged] + [fn for fn in merged if fn not in previous]
    return [merged[fn] for fn in order]


def validate(run, found, history):
    previous = {r["function"]: r for r in history[-1]["results"]} if history else {}
    results = merge_results(found, run.get("results", []), previous, len(history))

    coverage = run.get("coverage", {})
    if not isinstance(coverage, dict):
        raise InputError('"coverage" must be an object of metric name to percentage')
    metrics = {}
    for name, value in coverage.items():
        if not METRIC_RE.match(name):
            raise InputError(f'coverage metric "{name}" needs a short plain name')
        if name == FUNCTIONS_METRIC:
            raise InputError(f'"{FUNCTIONS_METRIC}" is computed from the results; leave it out')
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100:
            raise InputError(f'coverage metric "{name}" must be a percentage from 0 to 100')
        metrics[name] = float(value)

    bounds = run.get("bounds", "")
    notes = run.get("notes", "")
    if not isinstance(bounds, str) or not isinstance(notes, str):
        raise InputError('"bounds" and "notes" must be strings')
    if not bounds.strip():
        # The verifiers' own words, each once, where the agent gave none.
        fresh = [r["bounds"] for r in results if r.get("bounds") and not r.get("carried")]
        bounds = "; ".join(dict.fromkeys(fresh))

    passed = sum(1 for r in results if r["status"] == "PASS")
    metrics = {FUNCTIONS_METRIC: round(100.0 * passed / len(results), 1), **metrics}
    return {
        "results": results,
        "coverage": metrics,
        "bounds": bounds.strip(),
        "notes": notes.strip(),
    }


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def spec_section(spec, fn):
    """The function's `### <name>` section of spec.md, heading excluded."""
    match = re.search(rf"^###\s+`?{re.escape(fn)}`?\s*$(.*?)(?=^##|\Z)", spec, re.M | re.S)
    return match.group(1).strip() if match else ""


def attach_sources(run, project):
    """What each function was checked against, copied into the run as it is
    now: the harness and spec may change by the next run, and the report must
    show what this one verified."""
    spec = read_text(os.path.join(project, "spec.md"))
    for r in run["results"]:
        if r.get("carried"):
            continue  # Keeps what it was verified against, back then.
        harness = os.path.join(project, "harness", r["function"])
        r["spec"] = spec_section(spec, r["function"])
        r["check"] = read_text(os.path.join(harness, "check"))
        r["harness"] = read_text(os.path.join(harness, "main.c"))
        if not r["log"]:
            # ESBMC's own words, saved by the verifier's run of the check.
            r["log"] = cut_log(read_text(os.path.join(harness, "output.txt")))


def tool_version():
    """ESBMC's version as the binary on PATH reports it, asked here rather
    than told, so the report cannot name a version that did not run."""
    try:
        out = subprocess.run(["esbmc", "--version"], capture_output=True, text=True,
                             timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    match = re.search(r"\d+(?:\.\d+)+", out)
    return match.group(0) if match else "unknown"


def load_history(path):
    runs = []
    if not os.path.exists(path):
        return runs
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                runs.append(json.loads(line))
            except json.JSONDecodeError:
                # A torn line from an interrupted append: the rest still counts.
                print(f"report.py: skipping unreadable line {n} of {path}", file=sys.stderr)
    return runs


def write_atomic(path, text):
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def metric_names(history):
    names = [FUNCTIONS_METRIC]
    for run in history:
        for name in run.get("coverage", {}):
            if name not in names:
                names.append(name)
    return names


def fmt_pct(value):
    return "–" if value is None else f"{value:g}%"


def fmt_time(stamp):
    return datetime.datetime.fromisoformat(stamp).strftime("%Y-%m-%d %H:%M UTC")


def tool_text(run):
    tool = run.get("tool", {})
    return f"{tool.get('name', 'ESBMC')} {tool.get('version', 'unknown')}"


def result_text(r):
    status = f"FAIL ({r['blame']})" if r["status"] == "FAIL" else r["status"]
    detail = r["detail"]
    if r.get("carried"):
        detail = f"{detail} (not re-verified; from run {r['carried']})".strip()
    return status, detail


def summary_line(run):
    counts = {s: sum(1 for r in run["results"] if r["status"] == s) for s in STATUSES}
    total = len(run["results"])
    return (f"{counts['PASS']} of {total} functions verified, {counts['FAIL']} failing, "
            f"{counts['SKIP']} skipped.")


CAVEAT = ("A PASS holds only up to the loop bounds used; a SKIP is not verified "
          "at all.")


def previous_results(history):
    """Each function's result in the run before the latest, by name."""
    return {r["function"]: r for r in history[-2]["results"]} if len(history) > 1 else {}


def flip(before, now):
    """+1 where a function came to verify, -1 where it stopped. Verified is
    PASS alone, so a SKIP that now passes counts, as it does in coverage."""
    if before is None:
        return 0
    was, verified = before["status"] == "PASS", now["status"] == "PASS"
    return int(verified) - int(was)


def flips(history):
    """How many functions came to verify and how many stopped, or None on
    the first run."""
    if len(history) < 2:
        return None
    prev = previous_results(history)
    moves = [flip(prev.get(r["function"]), r) for r in history[-1]["results"]]
    return moves.count(1), moves.count(-1)


def flips_text(history):
    counts = flips(history)
    return "-" if counts is None else f"+{counts[0]} -{counts[1]}"


def flips_html(history):
    counts = flips(history)
    if counts is None:
        return "-"
    return f'<span class="PASS">+{counts[0]}</span> <span class="FAIL">-{counts[1]}</span>'


def previous_text(prev, r):
    before = prev.get(r["function"])
    return "-" if before is None else result_text(before)[0]


def md_cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def bar(value, width=20):
    filled = round(width * value / 100)
    return "█" * filled + "░" * (width - filled)


def render_markdown(history):
    run = history[-1]
    names = metric_names(history)
    out = ["# Verification Report", "", "## General Information", ""]
    out.append(f"- Date: {fmt_time(run['time'])}")
    out.append(f"- Verification tool: {tool_text(run)}")
    out.append(f"- Project: `{run['task']}`, run {len(history)}")
    out.append(f"- Flips since the previous run: {flips_text(history)}")
    out += ["", "## Verification", ""]
    out.append("| Function | Result | Detail |")
    out.append("| --- | --- | --- |")
    prev = previous_results(history)
    for r in run["results"]:
        status, detail = result_text(r)
        out.append(f"| `{md_cell(r['function'])}` | {previous_text(prev, r)} → **{status}** | {md_cell(detail)} |")
    out.append("")
    out.append(summary_line(run))
    if run["bounds"]:
        out.append(f"Loop bounds: {run['bounds']}.")
    out.append(CAVEAT)
    out += ["", "## Coverage", ""]
    out.append("| Run | Date | " + " | ".join(names) + " |")
    out.append("| --- | --- | " + " | ".join("---" for _ in names) + " |")
    for i, h in enumerate(history, 1):
        cells = [fmt_pct(h["coverage"].get(n)) for n in names]
        out.append(f"| {i} | {fmt_time(h['time'])} | " + " | ".join(cells) + " |")
    out.append("")
    out.append("```")
    width = len(str(len(history)))
    for i, h in enumerate(history, 1):
        value = h["coverage"][FUNCTIONS_METRIC]
        out.append(f"run {i:>{width}}  {bar(value)}  {value:g}%")
    out.append("```")
    out += ["", "## Notes", "", run["notes"] or "None.", ""]
    out += ["---", "", f"*{FOOTER}*", ""]
    return "\n".join(out)


def svg_chart(history, names):
    """The chart, and per run what its tooltip says and where it points."""
    w, h = 640, 260
    left, right, top, bottom = 44, 16, 14, 34
    pw, ph = w - left - right, h - top - bottom
    n = len(history)

    def x(i):
        return left + (pw / 2 if n == 1 else pw * i / (n - 1))

    def y(v):
        return top + ph * (1 - v / 100)

    parts = [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Coverage by run">']
    for v in (0, 25, 50, 75, 100):
        parts.append(f'<line class="grid" x1="{left}" x2="{w - right}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>')
        parts.append(f'<text class="axis" x="{left - 6}" y="{y(v) + 4:.1f}" text-anchor="end">{v}%</text>')
    step = max(1, -(-n // 12))
    for i in range(0, n, step):
        parts.append(f'<text class="axis" x="{x(i):.1f}" y="{h - 12}" text-anchor="middle">{i + 1}</text>')
    colours = [SERIES_COLOURS[k % len(SERIES_COLOURS)] for k in range(len(names))]
    for name, colour in zip(names, colours):
        points = [(i, x(i), y(r["coverage"][name])) for i, r in enumerate(history) if name in r["coverage"]]
        if len(points) > 1:
            path = " ".join(f"{px:.1f},{py:.1f}" for _, px, py in points)
            parts.append(f'<polyline fill="none" stroke="{colour}" stroke-width="2" points="{path}"/>')
        for i, px, py in points:
            parts.append(f'<circle class="pt" data-run="{i}" cx="{px:.1f}" cy="{py:.1f}" r="3.5" fill="{colour}"/>')
    # One column per run takes the pointer, so a run is easy to hit with a
    # finger rather than only on its 7-pixel dots.
    col = pw if n == 1 else pw / (n - 1)
    for i in range(n):
        parts.append(f'<rect class="hit" data-run="{i}" x="{x(i) - col / 2:.1f}" y="{top}" '
                     f'width="{col:.1f}" height="{ph}" fill="transparent"/>')
    parts.append("</svg>")
    legend = "".join(
        f'<span><i style="background:{colour}"></i>{html.escape(name)}</span>'
        for name, colour in zip(names, colours))
    tips = []
    for i, r in enumerate(history):
        values = [r["coverage"][n_] for n_ in names if n_ in r["coverage"]]
        tips.append({
            "title": f"Run {i + 1}, {fmt_time(r['time'])}",
            "lines": [f"{n_}: {fmt_pct(r['coverage'].get(n_))}" for n_ in names],
            "x": round(x(i), 1),
            "y": round(y(max(values)), 1),
        })
    chart = "\n".join(parts) + '\n<div class="tip" hidden></div>' + f'\n<p class="legend">{legend}</p>'
    return chart, tips


STYLE = """
[hidden] { display: none !important; }
.status { font-weight: 600; white-space: nowrap; }
/* Previous, arrow and current are three cells under one header, so each
   lines up in its own column. */
.prev { font-weight: 400; white-space: nowrap; padding-right: 0 !important; }
.arrow { color: var(--ink-faint, #8a8a8a); padding-left: 0.5rem !important;
  padding-right: 0.5rem !important; }
.arrow + .status { padding-left: 0 !important; }
.PASS { color: #3f7a3a; }
.FAIL { color: var(--accent, #8b1a1a); }
.SKIP { color: var(--ink-faint, #8a8a8a); }
.fn-row { cursor: pointer; }
.fn-row:hover td { background: var(--bg-alt, #ede8db); }
.fn-row a { text-decoration: none; }
.fn-row.up td:first-child { box-shadow: inset 3px 0 0 #3f7a3a; }
.fn-row.down td:first-child { box-shadow: inset 3px 0 0 var(--accent, #8b1a1a); }
.chart { position: relative; }
.chart svg { width: 100%; height: auto; display: block; }
.chart .grid { stroke: var(--rule-soft, #c9c2b3); stroke-width: 1; }
.chart .axis { fill: var(--ink-soft, #4a4a4a); font-size: 11px; }
.chart .hit { cursor: pointer; }
.chart .pt.on { r: 6; }
.tip { position: absolute; pointer-events: none; background: var(--ink, #1a1a1a);
  color: var(--bg, #f5f1e8); padding: 0.45rem 0.65rem; font-size: 0.85rem;
  line-height: 1.4; white-space: nowrap; box-shadow: 0 2px 8px rgba(0,0,0,0.2); }
.tip strong { display: block; font-weight: 600; }
.legend span { margin-right: 1.25rem; white-space: nowrap; }
.legend i { display: inline-block; width: 0.8em; height: 0.8em; margin-right: 0.35em; vertical-align: baseline; }
.notes { white-space: pre-wrap; }
.table-wrap { overflow-x: auto; }
pre.text { white-space: pre-wrap; }
.back { display: inline-block; margin-bottom: 1rem; }
footer { margin-top: 3rem; padding: 1rem 0; border-top: 1px solid var(--rule-soft, #c9c2b3);
  color: var(--ink-faint, #8a8a8a); font-size: 0.85rem; text-align: center; }
"""

SCRIPT = """
(() => {
  // A function's page is a view of this one file: the app styles only the
  // file it opens, so a second file would be unstyled.
  const overview = document.getElementById("overview");
  const pages = document.querySelectorAll(".fn-page");
  function route() {
    const page = location.hash && document.getElementById(location.hash.slice(1));
    const fn = page && page.classList.contains("fn-page") ? page : null;
    overview.hidden = !!fn;
    pages.forEach(p => { p.hidden = p !== fn; });
    if (fn) window.scrollTo(0, 0);
  }
  document.querySelectorAll(".fn-row").forEach(row => {
    row.addEventListener("click", () => { location.hash = row.dataset.page; });
  });
  addEventListener("hashchange", route);
  route();

  const tips = JSON.parse(document.getElementById("tips").textContent);
  const chart = document.querySelector(".chart");
  const svg = chart.querySelector("svg");
  const tip = chart.querySelector(".tip");
  function show(i) {
    const t = tips[i];
    const title = document.createElement("strong");
    title.textContent = t.title;
    tip.replaceChildren(title, ...t.lines.map(text => {
      const line = document.createElement("div");
      line.textContent = text;
      return line;
    }));
    svg.querySelectorAll(".pt").forEach(p => p.classList.toggle("on", p.dataset.run == i));
    tip.hidden = false;
    const vb = svg.viewBox.baseVal, box = svg.getBoundingClientRect(), outer = chart.getBoundingClientRect();
    const x = t.x / vb.width * box.width + box.left - outer.left;
    const y = t.y / vb.height * box.height + box.top - outer.top;
    const left = Math.min(Math.max(x - tip.offsetWidth / 2, 0), chart.clientWidth - tip.offsetWidth);
    tip.style.left = left + "px";
    tip.style.top = Math.max(y - tip.offsetHeight - 12, 0) + "px";
  }
  function hide() {
    tip.hidden = true;
    svg.querySelectorAll(".pt.on").forEach(p => p.classList.remove("on"));
  }
  svg.querySelectorAll(".hit").forEach(hit => {
    const i = Number(hit.dataset.run);
    // A mouse shows on hover; a touch has no hover and shows on the tap.
    hit.addEventListener("pointerenter", e => { if (e.pointerType === "mouse") show(i); });
    hit.addEventListener("click", e => { e.stopPropagation(); show(i); });
  });
  svg.addEventListener("pointerleave", e => { if (e.pointerType === "mouse") hide(); });
  document.addEventListener("click", hide);
})();
"""


def page_ids(results):
    """An element id per function, unique however the names collide once
    reduced to what an id may hold (C++'s `ns::f` and `ns_f`)."""
    ids, taken = {}, set()
    for r in results:
        base = "fn-" + re.sub(r"[^A-Za-z0-9_-]", "_", r["function"])
        pid, k = base, 2
        while pid in taken:
            pid, k = f"{base}-{k}", k + 1
        taken.add(pid)
        ids[r["function"]] = pid
    return ids


def block(title, text, missing):
    e = html.escape
    body = f'<pre class="text">{e(text)}</pre>' if text else f"<p>{e(missing)}</p>"
    return f"<h2>{e(title)}</h2>\n{body}"


def function_page(r, pid, past):
    """[past] is the function's (run number, time, result) in every run that
    has it, oldest first."""
    e = html.escape
    status, detail = result_text(r)
    rows = []
    for i, time, p in past:
        s, d = result_text(p)
        rows.append(f'<tr><td>{i}</td><td>{e(fmt_time(time))}</td>'
                    f'<td class="status {p["status"]}">{e(s)}</td><td>{e(d)}</td></tr>')
    # A carried result's sources are in the run that verified it.
    if r.get("carried"):
        src = next((p for i, _, p in past if i == r["carried"]), r)
        r = {**src, **r}
    log = block("Verifier output", r.get("log", ""), "") if r.get("log") else ""
    return f"""<section class="fn-page" id="{pid}" hidden>
<a class="back" href="#overview">&larr; Verification Report</a>
<h1><code>{e(r['function'])}</code></h1>
<p><span class="status {r['status']}">{e(status)}</span>{' &middot; ' + e(detail) if detail else ''}</p>
{'<p>Bounds: ' + e(r['bounds']) + '.</p>' if r.get('bounds') else ''}
{log}
{block("Specification", r.get("spec", ""), "This function has no section in spec.md.")}
{block("How it was checked", r.get("check", ""), "There is no check script for this function.")}
{block("Harness", r.get("harness", ""), "No harness: a static helper is checked directly, and a skipped function has none.")}
<h2>History</h2>
<div class="table-wrap"><table>
<thead><tr><th>Run</th><th>Date</th><th>Result</th><th>Detail</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table></div>
</section>"""


def render_html(history):
    run = history[-1]
    names = metric_names(history)
    e = html.escape
    ids = page_ids(run["results"])
    rows = []
    prev = previous_results(history)
    for r in run["results"]:
        status, detail = result_text(r)
        pid = ids[r["function"]]
        before = prev.get(r["function"])
        moved = {1: " up", -1: " down"}.get(flip(before, r), "")
        prev_class = f'prev {before["status"]}' if before else "prev"
        rows.append(f'<tr class="fn-row{moved}" data-page="{pid}"><td><a href="#{pid}"><code>{e(r["function"])}</code></a></td>'
                    f'<td class="{prev_class}">{e(previous_text(prev, r))}</td><td class="arrow">&rarr;</td>'
                    f'<td class="status {r["status"]}">{e(status)}</td><td>{e(detail)}</td></tr>')
    bounds = f"<p>Loop bounds: {e(run['bounds'])}.</p>" if run["bounds"] else ""
    notes = f'<p class="notes">{e(run["notes"])}</p>' if run["notes"] else "<p>None.</p>"
    chart, tips = svg_chart(history, names)
    # Inside a <script>, only "</" can end it early.
    tips_json = json.dumps(tips, ensure_ascii=False).replace("</", "<\\/")
    by_function = {}
    for i, h in enumerate(history, 1):
        for p in h["results"]:
            by_function.setdefault(p["function"], []).append((i, h["time"], p))
    pages = "\n".join(function_page(r, ids[r["function"]], by_function[r["function"]])
                      for r in run["results"])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Verification Report: {e(run['task'])}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
<section id="overview">
<h1>Verification Report</h1>

<h2>General Information</h2>
<ul>
<li>Date: {e(fmt_time(run['time']))}</li>
<li>Verification tool: {e(tool_text(run))}</li>
<li>Project: <code>{e(run['task'])}</code>, run {len(history)}</li>
<li>Flips since the previous run: {flips_html(history)}</li>
</ul>

<h2>Verification</h2>
<div class="table-wrap"><table>
<thead><tr><th>Function</th><th colspan="3">Result</th><th>Detail</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table></div>
<p>{e(summary_line(run))}</p>
{bounds}
<p>{e(CAVEAT)}</p>

<h2>Coverage</h2>
<div class="chart">
{chart}
</div>

<h2>Notes</h2>
{notes}
</section>
{pages}
<footer>{FOOTER}</footer>
</main>
<script type="application/json" id="tips">{tips_json}</script>
<script>{SCRIPT}</script>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", help="the run as a JSON file, or - for stdin")
    parser.add_argument("project", help="the directory of the code being verified")
    parser.add_argument("--run", required=True,
                        help="the id the verifiers wrote their results under, "
                             "in .entoli/byte-repair/results/<run>/")
    parser.add_argument("--git", choices=("keep", "ignore"),
                        help="whether git keeps .entoli/byte-repair/ (the user's "
                             "choice); left out, the last choice stands")
    args = parser.parse_args()

    project = os.path.realpath(args.project)
    if not os.path.isdir(project):
        fail(f"{args.project} is not a directory; pass the directory of the code being verified")
    if not RUN_RE.match(args.run):
        fail(f"--run {args.run} is not a run id, such as 20261023T112500Z")
    data_dir = os.path.join(project, *DATA_DIR)
    history_path = os.path.join(data_dir, "history.jsonl")
    history = load_history(history_path)
    try:
        found = read_results(os.path.join(project, *RESULTS_DIR, args.run))
        run = validate(read_run(args.input), found, history)
    except InputError as err:
        fail(str(err))

    # A directory of its own: publishing copies the page's whole directory,
    # and the history is not the page's to carry.
    report_dir = os.path.join(data_dir, "html")
    os.makedirs(report_dir, exist_ok=True)
    set_git(project, os.path.join(project, *ROOT_DIR), args.git)

    run["run"] = args.run
    run["task"] = os.path.basename(project)
    run["time"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    run["tool"] = {"name": "ESBMC", "version": tool_version()}
    attach_sources(run, project)
    with open(history_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(run, ensure_ascii=False) + "\n")
    history.append(run)

    markdown = render_markdown(history)
    write_atomic(os.path.join(data_dir, "report.md"), markdown)
    write_atomic(os.path.join(report_dir, "index.html"), render_html(history))

    print(markdown, flush=True)
    print(f'Publish with the artifact tool: path "{artifact_path(os.path.join(report_dir, "index.html"))}", '
          f'title "Verification Report: {run["task"]}"', file=sys.stderr)


def git_exclude(project):
    """The repository's top and its info/exclude, or None outside one. Git
    answers where it can, worktrees and submodules included; a guest with
    no git is answered by walking up to a .git directory, the plain clone's
    layout. A .git file there (a worktree, a submodule) is git's to read, so
    without git it counts as no repository."""
    try:
        out = subprocess.run(
            ["git", "-C", project, "rev-parse", "--show-toplevel", "--git-path", "info/exclude"],
            capture_output=True, text=True, timeout=10)
        lines = out.stdout.splitlines()
        if out.returncode == 0 and len(lines) >= 2:
            return lines[0], os.path.join(project, lines[1])
    except (OSError, subprocess.SubprocessError):
        pass
    d = project
    while True:
        dot = os.path.join(d, ".git")
        if os.path.isdir(dot):
            return d, os.path.join(dot, "info", "exclude")
        if os.path.exists(dot):
            return None
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def set_git(project, reports, choice):
    """Whether the records are committed with the code is the user's to say.
    The choice lives in .git/info/exclude, which is the clone's own and never
    committed, so the repository gains no file for it. A run with no choice
    leaves the line as it is; keep removes only that line."""
    if choice is None:
        return
    found = git_exclude(project)
    if found is None:
        print(f"report.py: {project} is in no git repository; --git {choice} "
              "has nothing to do", file=sys.stderr)
        return
    top, exclude = found
    entry = "/" + os.path.relpath(reports, os.path.realpath(top)).replace(os.sep, "/") + "/"
    try:
        with open(exclude, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    if choice == "ignore" and entry not in lines:
        lines.append(entry)
    elif choice == "keep" and entry in lines:
        lines = [line for line in lines if line != entry]
    else:
        return
    os.makedirs(os.path.dirname(exclude), exist_ok=True)
    write_atomic(exclude, "\n".join(lines) + "\n" if lines else "")


def artifact_path(entry):
    """The artifact tool's own words for the page, so publishing it is a copy
    rather than a path the model builds. The chat workspace is inside the
    project's, so it is asked first."""
    for prefix, var in (("chat:", "ENTOLI_CHAT_WORKSPACE"), ("project:", "ENTOLI_PROJECT_WORKSPACE")):
        root = os.environ.get(var)
        if not root:
            continue
        try:
            rel = os.path.relpath(entry, os.path.realpath(root))
        except ValueError:  # Windows: another drive.
            continue
        if not rel.startswith(os.pardir):
            return prefix + rel.replace(os.sep, "/")
    return entry


if __name__ == "__main__":
    main()
