---
name: verification-report
description: Record a Byte Repair verification run and publish its standard report, the results of every function, coverage over time and notes. Use at the end of every verification, as the final report to the user.
---

This turns a verification run into the standard report: the same Markdown
every time, and an HTML artifact with the coverage history. The results come
from the verifiers themselves: each wrote
`<project>/.entoli/byte-repair/results/<run>/harness-<function>.json`, and the
script reads them, so you do not copy a result by hand. The history is kept
beside them, in `<project>/.entoli/byte-repair/reports/`, so it stays with the
code wherever it lives and grows across conversations that work on it. Do
not edit anything under `.entoli/` by hand.

## 1. Write what only you know

Write it as JSON with the `write` tool, to `chat:verification-run.json`:

    {
      "results": [
        {"function": "ini_find", "status": "SKIP", "detail": "nested loops (shell function)"},
        {"function": "parse_int", "blame": "spec",
         "detail": "the spec allows a negative result the code never returns"}
      ],
      "coverage": {"Branch": 82.5},
      "notes": "parse_int's spec needs the user's call on negative input."
    }

- `results`: only what the verifiers' files do not say.
  - A shell function, which no verifier checked: its SKIP, with the reason
    the spec gives.
  - A FAIL whose cause you traced further than the verifier did: its
    function, the `blame` you settled on (`code`, `contract` or `spec`) and,
    if it helps, a `detail`. You cannot change a status the verifier found;
    the script refuses it.
  - Leave everything else out. A function not verified in this run keeps its
    result from the last report, marked as not re-verified.
- `coverage`: optional. Any further coverage measure you have, by name, as a
  percentage from 0 to 100, such as ESBMC's branch coverage. Use the same names
  every run, so the history lines up. Leave out "Functions verified": the
  script computes it from the results.
- `bounds`: optional. Left out, the report gives the bounds the verifiers
  wrote.
- `notes`: anything the user should know that the table does not say: what
  changed since the last run, assumptions, what is left to do.

## 2. Run the script

    python3 <base directory>/scripts/report.py "$ENTOLI_CHAT_WORKSPACE/verification-run.json" "<project>" --run <run>

where `<base directory>` is this skill's, given above, `<project>` is the
project as a command names it, such as `$ENTOLI_PROJECT_WORKSPACE/ini-parser`,
and `<run>` is the run id you gave the verifiers. The report is named after the project's
directory, and each function's page shows its section of `spec.md`, its
`check` script, its harness and ESBMC's output, read from there.

If the project is a git repository, whether git keeps the records is the
user's choice, asked before the work started. On the project's first report,
add `--git keep` to commit them with the code, or `--git ignore` to keep them
out (the script lists `.entoli/byte-repair/` in the clone's own
`.git/info/exclude`, so the repository gains no file). The choice is remembered,
so later runs leave the flag off unless the user changes their mind.

The script stores the run and prints the report. If it refuses the input, it
says what to fix: fix your JSON, or for a verifier's file that is broken, run
that verifier again, then run the script again. A refused run is not stored.

## 3. Publish and report

Publish the HTML with the `artifact` tool, using the path and title on the
line the script printed starting "Publish with the artifact tool". If you
already published this project's report in this conversation, pass that
`artifact_id` too, so the report updates in place.

Then your reply to the user is the Markdown report the script printed, from
`# Verification Report` to its closing "Generated with Entoli" line, exactly
as printed. Add nothing before it; one or two sentences after it at most.
