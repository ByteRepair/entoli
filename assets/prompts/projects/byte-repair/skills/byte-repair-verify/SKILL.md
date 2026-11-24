---
name: byte-repair-verify
description: Write C in a Byte Repair project and prove its core functions with ESBMC, from spec to verification report. Use for every request to write, change or fix code in a Byte Repair project, unless the user asks to skip verification.
---

This runs a verification task from the request to the report. You do the
spec, the contracts and the code yourself, in this conversation, because each
step needs everything the one before it found. Only the checks go to
sub-agents: one `esbmc-verifier` per function, run at once, since each is
independent and its ESBMC runs and traces would crowd this conversation.

## Inputs

The user's request, and the project: new, cloned, or already in a workspace.
Ask the system instructions' questions about where it lives and whether git
keeps its records first, in one `ask_user` call. Where the spec step finds
blocking questions, ask them in that same call if you can tell them from the
request alone, so the user is asked once.

## Layout

A new project gets its own kebab-case directory, for example `ini-parser/`:

- `ini-parser/spec.md`: the specification (`byte-repair-spec`).
- `ini-parser/src/`: the code, with its contracts (`byte-repair-contracts`).
- `ini-parser/harness/`: written by `esbmc-verifier`; never edit it.
- `ini-parser/Makefile`: written once (`byte-repair-verify`).
- `ini-parser/.entoli/byte-repair/`: the verifiers' results under
  `results/<run>/` and the verification history under `reports/`, written by
  `esbmc-verifier` and the `verification-report` skill. Never edit it.
  Whether git keeps it is the user's choice.

## Writing the code

- Write C. Use C++ only when the task requires it, and then avoid templates
  and exceptions, which ESBMC handles poorly.
- Keep each body to the decomposition in the spec: one job per function.
- `gcc` may not be installed, and you do not need it: ESBMC parses the source
  itself. Do not compile-check files as you write them. Do not run ESBMC
  yourself either; that is the verifier's job.

## Steps

1. **Spec.** Load `byte-repair-spec` with the `skill` tool and follow it.
   Ask the user its blocking questions there, before writing.
2. **Contracts.** Load `byte-repair-contracts` and follow it: every stub
   with its contract, before any body.
3. **Code.** Write each body. Do not change a contract statement while
   writing one; a contract that looks wrong goes through Changing a contract
   in `byte-repair-contracts`. Then write the Makefile below, once.
4. **Verify.** Pick a run id, the current UTC time as `date -u
   +%Y%m%dT%H%M%SZ` prints it, and keep it until you report: every round of
   steps 4 and 5 uses the same one. Send one `task` call per core function,
   under `esbmc-verifier`, all in one message so they run at once. Each
   prompt names the project both ways, as the file tools take it
   (`project:ini-parser` or `chat:ini-parser`) and as a command takes it
   (`$ENTOLI_PROJECT_WORKSPACE/ini-parser` or
   `$ENTOLI_CHAT_WORKSPACE/ini-parser`), the one function, the file that
   holds it, and the run id.
   A verifier sees nothing of this conversation; that is all it needs.
5. **Fix.** For each FAIL, trace the counterexample through the code
   yourself; the verifier's blame is a lead, not a verdict. Decide what is
   wrong: the code (fix the body), the contract or the spec (follow Changing
   a contract). Verify again every function the fix could change, under the
   same run id. After three rounds, stop and report what still fails.
6. **Report.** Load `verification-report` and follow it, with the run id.
   Its notes list every contract statement changed in the run, with the spec
   line behind each. Do not write your own report instead.

For a small change to a finished project, skip the steps it does not touch:
a fix to one body needs only steps 3 to 6 for that function, under a new run
id. Functions not verified again keep their last result in the report.

## The Makefile

Each verifier writes its function's command to `harness/<function>/check`.
The Makefile runs them all, so `make -C <project> verify` checks the whole
project:

    verify:
    	@status=0; for c in harness/*/check; do \
    		echo "== $$c"; sh "$$c" || status=1; \
    	done; exit $$status

The recipe lines start with a tab.

## Success criteria

- Every core function in the spec has a result in this run: PASS, FAIL or
  SKIP.
- Every contract statement traces to a spec line; every one changed in the
  run is listed in the report's notes with that line.
- No contract was weakened without the check in `byte-repair-contracts`.
- Every FAIL in the report has a blame you traced yourself.
- The reply calls nothing proven beyond what the report says.

## Output

The `verification-report` skill's reply, as it says.
