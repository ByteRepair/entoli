---
name: deep-research
description: Runs a deep research pipeline over a question — searches the web from several angles, fetches the sources, verifies each claim against adversarial votes, and synthesizes a cited report. Use when the user wants a fact-checked, multi-source answer rather than a quick summary.
metadata:
  argument-hint: "<question>"
---
The research question is in $ARGUMENTS.

Before anything runs: where the question is underspecified — "which car
should I buy" with no budget, use case, or region — call `ask_user` with two
or three questions that narrow it, each with its answers to pick from, then
carry on with what the user gave you woven into the question. A question that
is already specific starts the pipeline straight away.

## The budget, fixed for every run

Do not adjust these to suit a run:

- search angles: three to six, five aimed for
- 15 sources fetched, at most
- 25 claims verified, at most
- 3 adversarial votes per claim
- 2 refutations of 3 kill a claim

## Phase 0 — Scope the question

Send one `task` call, under `general`, with the question and this brief:

```
Break this research question into complementary search angles.

## Question
<QUESTION>

## Task
Write five distinct web search queries that between them cover the question
from different sides, chosen for this question's domain. Examples of the
sides a question can have:
- the primary/established view · the academic or technical literature ·
  recent news · the skeptical/contrarian take · the practitioner's account
- medical: anatomy · common causes · serious differentials · authoritative
  references · red flags
- technical: state of the art · benchmarks · limitations · industry adoption
  · cost and trade-offs

Queries should be specific enough to pull high-signal results, and no two
should overlap.

Answer as JSON only:
{"question": "<the question, lightly normalized>",
 "summary": "<one or two sentences on how you decomposed it>",
 "angles": [{"label": "...", "query": "...", "rationale": "..."}]}
```

Say what came back: the question, the decomposition, and the angle labels.

If the worker produced nothing, stop and tell the user the scoping step
failed and the question could not be decomposed.

## Phase 1 — Search the angles

Send one `task` call per angle, all in one message so they run side by side
(more angles than run slots queue as capacity frees — that is fine). Each
runs under `general` with this brief, its angle substituted in:

```
## Searcher: <angle.label>

Research question: "<QUESTION>"
Your angle: **<angle.label>** — <angle.rationale>
Your query: `<angle.query>`

## Task
Run `websearch` with your query, or a sharpened version of it. Return the
four to six results most relevant to the ORIGINAL question — not merely to
your query — ranked by that relevance. Obvious SEO spam and content farms
are skipped. For each result include a short snippet saying why it matters
to the question.

Answer as JSON only:
{"results": [{"url": "...", "title": "...", "snippet": "...",
              "relevance": "high|medium|low"}]}
```

Collect every result. Where fewer than three searchers returned anything,
stop: too many searchers failed for the run to go on, and the user is told
to retry rather than shown a half-empty report.

Say each angle's count as it lands.

## Phase 2 — Dedup the URLs, budget the fetches

Over all the searchers' results, build a dedup key per URL: drop the scheme,
everything up to and including the last `@` before the host, a leading
`www.`, and the port; keep host plus path, lowercased. Drop any URL whose key
you have already seen, recording it as a duplicate.

Cap the survivors at 15 sources. Over budget, drop by relevance first — low
before medium, medium before high — recording what the budget dropped. An
angle keeps up to six results; the global cap still binds.

Say how many novel URLs, how many duplicates, how many budget-dropped.

## Phase 3 — Fetch and extract

Send one `task` call per surviving source, all in one message. Each runs
under `general` with this brief, its source substituted in:

```
## Source extractor

Research question: "<QUESTION>"
Source URL: <source.url>
Source title: <source.title>
Found by: the <angle> search

## Task
1. `webfetch` the URL and read the page.
2. Judge what kind of source it is: primary research or an institution,
   secondary reporting, a blog or opinion piece, a forum thread, or nothing
   usable.
3. Extract two to five claims that bear on the question. Each claim is
   falsifiable — a concrete statement a reader could check, not a generality
   — carries a direct quote from the source as its support, and is rated
   central, supporting, or tangential to the question.
4. Note the publish date where the page shows one.

Where the fetch fails, or the page is irrelevant or paywalled, return
sourceQuality "unreliable" and claims [].

Answer as JSON only:
{"sourceQuality": "primary|secondary|blog|forum|unreliable",
 "publishDate": "...",
 "claims": [{"claim": "...", "quote": "...",
             "importance": "central|supporting|tangential"}]}
```

Collect the claims, each stamped with its source's URL and quality. A failed
fetch yields no claims.

## Phase 4 — Rank the claims

Order the pool: importance first (central over supporting over tangential),
then source quality (primary over secondary over blog over forum over
unreliable). Verify the top 25.

Say what the run has: N sources fetched, M claims extracted, K to verify.
Where K is 0, jump to the fallback at the end and stop.

## Phase 5 — Verify, three votes per claim

Nothing here starts until the claim pool is complete.

Send three `task` calls per claim — up to 75 in one message — each under
`general`, each one vote. The brief each carries:

```
## Adversarial verifier (vote <n> of 3)

Be skeptical. Your job is to refute this claim: two or more refuters of the
three kill it.

## Research question
<QUESTION>

## Claim under review
"<claim>"

**Source:** <sourceUrl> (<sourceQuality>)
**Supporting quote:** "<quote>"

## Checklist
1. Does the quote actually support the claim, or is the claim an overreach or
   a misread of it?
2. `websearch` for contradicting evidence: does any credible source dispute
   the claim, or qualify it heavily?
3. Is the source strong enough for a claim this strong? An extraordinary
   claim wants a primary source.
4. Is the claim stale? An old claim about a fast-moving field is suspect.
5. Is this marketing, a press release, a cherry-picked benchmark, or forum
   speculation?

**refuted=true** where: the quote does not support it, the evidence
contradicts it, the source is too weak for the claim's strength, the claim is
outdated, or it reads as marketing.
**refuted=false** only where the claim is well supported, current, and the
source's quality matches the claim's strength.
When uncertain, refute.

Answer as JSON only:
{"refuted": true|false, "evidence": "<specific reasoning>",
 "confidence": "high|medium|low"}
```

Tally each claim's panel:

- valid votes: the verdicts that arrived at all
- a vote that errored or returned nothing is not a vote
- the claim **survives** with at least two valid votes and fewer than two
  refutations
- it is **refuted** at two or more refutations
- otherwise it is **unverified** — too few valid votes, the verifiers failed

Say each verdict as it tallies.

## Phase 5b — Read the tally honestly

Sort the claims three ways: confirmed (survived), killed (refuted),
unverified (neither).

Failure is not the same as refutation, and the report must not confuse them:

- Every verifier panel failed and nothing was killed — rate limits or API
  errors, most likely. Say so plainly: an infrastructure failure, and a retry
  is worth it. This is not a research result.
- Some panels failed and some claims were killed on merit — report both,
  labeled as what they are.
- Every claim killed: say the research came back inconclusive, the sources
  were weak or the claims overstated.

"Unverified" never reads as "the research found nothing": it reads as the
verifiers not having been able to run.

## Phase 6 — Synthesize

Where nothing was confirmed, return the Phase 5b account — the
infrastructure failure, the all-refuted result, or the honest mix — with the
refuted and unverified claims listed and an empty findings list. Nothing is
invented to fill the shape.

Where claims were confirmed, send one `task` call, under `general`, with this
brief:

```
## Research synthesis

**Question:** <QUESTION>

<confirmed count> claims survived 3-vote adversarial verification. Merge
semantic duplicates and synthesize.

## Confirmed claims
<for each confirmed claim, in order>
### [i] <claim>
Vote: <valid>-<refuted> · Source: <sourceUrl> (<sourceQuality>)
Quote: "<quote>"
Verifier evidence (<confidence>): <evidence>

## Refuted claims (for transparency)
<where any: each killed claim>
- "<claim>" (<sourceUrl>, vote <valid>-<refuted>)
<omit the section where none>

## Unverified claims (<N> — the verifier agents failed)
<where any: each unverified claim>
- "<claim>" (<sourceUrl>, <errored> of 3 votes failed)

Say in the caveats that <N> claims could not be verified because the
infrastructure failed.
<omit the section where none>

## Instructions
1. Claims saying the same thing merge, their sources combining.
2. Related claims group into findings, and each finding answers part of the
   research question.
3. Confidence per finding: high — several primary sources, unanimous votes;
   medium — secondary sources or split votes; low — one source, or a weak one.
4. A 3-5 sentence executive summary answering the research question.
5. Caveats: what stayed uncertain, which sources were weak, what is
   time-sensitive.
6. Two to four open questions the research surfaced but left unanswered.

Answer as JSON only:
{"summary": "...",
 "findings": [{"claim": "...", "confidence": "high|medium|low",
               "sources": ["url", ...], "evidence": "...", "vote": "2-1"}],
 "caveats": "...", "openQuestions": ["...", ...]}
```

## Phase 7 — Write the report

Render the result as prose for the user, never as raw JSON. Number the
sources in the text and list every cited source at the end, numbered to
match — always, whatever the reply settings say.

```
# Research: <question>

<summary>

## Findings
<each finding, numbered, with its confidence, its sources as links, and the
evidence behind it>

## Refuted claims (transparency)
<where any, else omit>

## Unverified claims
<where any, carrying the infrastructure caveat, else omit>

## Caveats
<caveats>

## Open questions
<openQuestions>

## References
<every source cited above, numbered, one per line: title — url>

## Stats
angles: N · sources fetched: N · claims extracted: N · verified: N ·
confirmed: N · refuted: N · unverified: N · after synthesis: N
```

### Fallback: synthesis failed

Where the synthesis step returned nothing, salvage the confirmed claims raw
and say the synthesis did not run:

```
# Research: <question>

The synthesis step failed — returning <N> verified claims unmerged.

## Confirmed claims (unmerged)
<each with its claim, source url, quote, and vote>

## Refuted claims (transparency)
<where any, else omit>

## Unverified claims
<where any, else omit>

## Stats
<stats>
```

Do not fabricate findings in either shape. An empty findings list with the
reason beside it is an honest report; invented findings are not.