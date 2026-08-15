---
description: Deep research — fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report
agent: build
subtask: true
---
`/deep-research <question>` - 5 angles → search → fetch+extract → 3-vote verify → synthesize

You are running a deep research pipeline. The research question is in $ARGUMENTS.

BEFORE starting: if the question is underspecified (e.g. "what car to buy" without budget/use-case/region), call the `ask_user` tool with 2-3 clarifying questions to narrow scope, each with the answers to pick from. Once you have enough, proceed — weaving the answers into the question. If the question is already specific, skip this and go straight to Phase 0.

## Constants

These are fixed for every run. Do not change them:
- 5 search angles (Phase 0 produces 3-6; aim for 5)
- MAX_FETCH = 15 sources fetched
- MAX_VERIFY_CLAIMS = 25 claims verified
- VOTES_PER_CLAIM = 3 adversarial verifiers per claim
- REFUTATIONS_REQUIRED = 2 refutes out of 3 kills a claim

## Phase 0 — Scope

Launch ONE @general agent via the task tool. Give it the research question and this task:

```
Decompose this research question into complementary search angles.

## Question
<QUESTION>

## Task
Generate 5 distinct web search queries that together cover the question from different angles. Pick angles that suit the question's domain. Examples:
- broad/primary · academic/technical · recent news · contrarian/skeptical · practitioner/implementation
- For medical: anatomy · common causes · serious differentials · authoritative refs · red flags
- For tech: state-of-art · benchmarks · limitations · industry adoption · cost/tradeoffs

Make queries specific enough to surface high-signal results. Avoid redundancy.
Return: the question (verbatim or lightly normalized), a 1-2 sentence decomposition strategy, and the angles.

Return strict JSON only:
{"question": "...", "summary": "1-2 sentence decomposition strategy",
 "angles": [{"label": "...", "query": "...", "rationale": "..."}]}
```

Wait for it. If it returns nothing, stop and report: "Scope agent returned no result — cannot decompose the research question."

Log: "Q: <question> — Decomposed into N angles: <labels>"

## Phase 1 — Search

Launch 5 @general agents via the task tool, ALL IN A SINGLE MESSAGE so they run concurrently. Each gets one angle and this task (substitute the angle's fields):

```
## Web Searcher: <angle.label>

Research question: "<QUESTION>"
Your angle: **<angle.label>** — <angle.rationale>
Search query: `<angle.query>`

## Task
Use websearch with the query above (or a refined version). Return the top 4-6 most relevant results. Rank by relevance to the ORIGINAL question, not just the search query. Skip obvious SEO spam/content farms. Include a short snippet capturing why each result is relevant.

Return strict JSON only:
{"results": [{"url": "...", "title": "...", "snippet": "...", "relevance": "high|medium|low"}]}
(max 6 results)
```

Wait for all 5. Collect all results.

Log per angle: "<label>: N results"

## Phase 1b — URL dedup + fetch budget

Before fetching, dedup across all 5 searchers' results:
- Normalize each URL: strip scheme, userinfo (everything up to and including the last @ before the host), leading www., and port; keep hostname + path; lowercase. This is the dedup key. Drop any URL whose key was already seen (record it as a dupe).
- Cap at MAX_FETCH (15) sources. If over budget, drop lowest-relevance first (low before medium before high). Record budget-dropped sources.
- Keep up to 6 results per angle, but the global cap is 15 total.

Log: how many novel, how many dupes, how many budget-dropped.

## Phase 2 — Fetch + Extract

Launch ONE @general agent per surviving source, ALL IN A SINGLE MESSAGE so they run concurrently. Each gets:

```
## Source Extractor

Research question: "<QUESTION>"
Fetch and extract key claims from this source:
**URL:** <source.url>
**Title:** <source.title>
**Found via:** <angle> search

## Task
1. Use webfetch to retrieve the page content.
2. Assess source quality: primary research/institution? secondary reporting? blog/opinion? forum? unreliable?
3. Extract 2-5 FALSIFIABLE claims that bear on the research question. Each claim must:
   - be a concrete, checkable statement (not vague generalities)
   - include a direct quote from the source as support
   - be rated central/supporting/tangential to the research question
4. Note publish date if available.

If the fetch fails or the page is irrelevant/paywalled, return claims: [] and sourceQuality: "unreliable".

Return strict JSON only:
{"sourceQuality": "primary|secondary|blog|forum|unreliable",
 "publishDate": "...",
 "claims": [{"claim": "...", "quote": "...", "importance": "central|supporting|tangential"}]}
(max 5 claims)
```

Wait for all. For each result, attach sourceUrl and sourceQuality to each claim. A failed fetch → sourceQuality "unreliable", claims [].

## Phase 2b — Rank claims

Collect all claims across all sources. Rank by:
- importance (central > supporting > tangential), then
- sourceQuality (primary > secondary > blog > forum > unreliable)

Take the top MAX_VERIFY_CLAIMS (25).

Log: "Fetched N sources → M claims → verifying top K"

If K is 0: return the empty-report shape (see Phase 5 fallback) and stop.

## Phase 3 — Verify

This is a BARRIER — the claim pool must be fully assembled before verification.

For each of the top K claims, launch 3 @general agents (VOTES_PER_CLAIM = 3). That's up to 75 agents. Launch them ALL IN A SINGLE MESSAGE so they run concurrently. Each voter gets:

```
## Adversarial Claim Verifier (voter <v+1>/3)

Be SKEPTICAL. Try to REFUTE this claim. ≥2/3 refutations kill it.

## Research question
<QUESTION>

## Claim under review
"<claim.claim>"

**Source:** <claim.sourceUrl> (<claim.sourceQuality>)
**Supporting quote:** "<claim.quote>"

## Checklist
1. Is the claim actually supported by the quote, or is it an overreach/misread?
2. websearch for contradicting evidence — does any credible source dispute or heavily qualify this?
3. Is the source quality sufficient for the claim's strength? (extraordinary claims need primary sources)
4. Is the claim outdated? (check dates — old claims about fast-moving fields are suspect)
5. Is this a marketing claim / press release / cherry-picked benchmark / forum speculation?

**refuted=true** if: unsupported by quote / contradicted / low-quality source for strong claim / outdated / marketing fluff.
**refuted=false** ONLY if: claim is well-supported, current, and source quality matches claim strength.
Default to refuted=true if uncertain.

Return strict JSON only:
{"refuted": true|false, "evidence": "specific reasoning",
 "confidence": "high|medium|low", "counterSource": "url or omit"}
```

Wait for all votes. A vote can be null (agent errored or returned nothing) — treat as no vote cast.

For each claim, tally:
- valid votes = non-null verdicts
- refuted = count where refuted=true
- errored = 3 - valid.length
- survives   if valid.length >= 2 AND refuted < 2
- isRefuted  if refuted >= 2
- otherwise  unverified (too few valid votes — verifier agents errored)

Log each claim: `"<claim[:50]>…": <valid-refuted>-<refuted> [<errored> errored] ✓|✗|?`

## Phase 3b — Tally

Partition claims into:
- confirmed (survives)
- killed (isRefuted)
- unverified (neither)

CRITICAL — distinguish "refuted on merit" from "could not verify (infra failure)":
- If killed.length == 0 AND unverified.length > 0: all verifier panels failed (likely rate-limiting or API errors). This is an INFRASTRUCTURE FAILURE, not a research finding. Report it as such so the user knows to retry.
- If unverified.length > 0 AND killed.length > 0: mixed — report both honestly.
- If all killed: "All N claims refuted. Research inconclusive — sources may be low-quality or claims overstated."

The unverified state must NEVER be read as "the research found nothing." It means the verifiers couldn't run.

Log: "Verify done: N claims → C confirmed, R refuted, U unverified"

## Phase 4 — Synthesize

If confirmed.length == 0: return the appropriate summary from Phase 3b (infra failure vs. all-refuted vs. mixed), with findings: [], plus the refuted and unverified lists and sources. Do NOT fabricate findings. Go directly to Phase 5.

Otherwise launch ONE @general agent:

```
## Synthesis: research report

**Question:** <QUESTION>

<confirmed.length> claims survived 3-vote adversarial verification. Merge semantic duplicates and synthesize.

## Confirmed claims
<for each confirmed claim, in order>
### [i] <claim>
Vote: <valid-refuted>-<refuted> · Source: <sourceUrl> (<sourceQuality>)
Quote: "<quote>"
Verifier evidence (<confidence>): <evidence>

## Refuted claims (for transparency)
<if any: for each killed claim>
- "<claim>" (<sourceUrl>, vote <valid-refuted>-<refuted>)
<else: omit this section>

## Unverified claims (<N> — verifier agents failed; neither confirmed nor refuted)
<if any: for each unverified claim>
- "<claim>" (<sourceUrl>, <errored>/3 votes errored)

Mention in caveats that <N> claim(s) could not be verified due to infrastructure errors.
<else: omit this section>

## Instructions
1. Identify claims that say the same thing — merge them, combine their sources.
2. Group related claims into coherent findings. Each finding should directly address the research question.
3. Assign confidence per finding: high (multiple primary sources, unanimous votes), medium (secondary sources or split votes), low (single source or blog-quality).
4. Write a 3-5 sentence executive summary answering the research question.
5. Note caveats: what's uncertain, what sources were weak, what time-sensitivity applies.
6. List 2-4 open questions that emerged but weren't answered.

Return strict JSON only:
{"summary": "...",
 "findings": [{"claim": "...", "confidence": "high|medium|low", "sources": ["url", ...], "evidence": "...", "vote": "2-1"}],
 "caveats": "...",
 "openQuestions": ["...", ...]}
```

Wait for it.

## Phase 5 — Return

Return the final report to the user as a cited report, not raw JSON. Render it as:

```
# Research: <question>

<summary>

## Findings
<for each finding, numbered, with confidence, sources as links, evidence>

## Refuted claims (transparency)
<if any; else omit>

## Unverified claims
<if any — with the infra-failure caveat; else omit>

## Caveats
<caveats>

## Open questions
<openQuestions>

## Stats
angles: N · sources fetched: N · claims extracted: N · verified: N ·
confirmed: N · refuted: N · unverified: N · after synthesis: N
```

### Fallback: synthesis failed

If the synthesis agent returns nothing: salvage the verified claims raw — return:

```
# Research: <question>

Synthesis step was skipped or failed — returning <N> verified claims unmerged.

## Confirmed claims (unmerged)
<for each: claim, source url, quote, vote>

## Refuted claims (transparency)
<if any>

## Unverified claims
<if any>

## Stats
<stats>
```

Do NOT fabricate findings.