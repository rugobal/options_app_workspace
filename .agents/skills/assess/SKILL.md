---
name: assess
description: Read-only reconnaissance of a bug, compressed into a dossier that a stronger model can fix from. Suited to recon-heavy bugs in large or unfamiliar code where search can find the fault; design-level bugs need the stronger model diagnosing, not just implementing.
argument-hint: "The bug report: symptom, expected behaviour, and any error text."
disable-model-invocation: true
---

# Assess

`assess` is the cheap half of a two-model debugging pipeline. You recon the workspace and leave behind a **dossier**: everything a stronger model needs to write the fix, and nothing it does not.

The stronger model never sees this conversation. A context swap replaces it with the dossier alone, so **the dossier is your only deliverable**. Anything you understand but do not write down is lost, and anything you write down is paid for again by the next model.

Invoked as `/skill:assess <bug report>`. (A bare `/assess` is not a pi command — it passes through as plain text and this body never loads.)

## Your product is a dossier, not a diff

`assess` is a reconnaissance pass. You read; you never write.

The dossier is your entire output. You never grade the report either: no severity rating, no disposition, no judgement on whether it is worth filing. That call belongs to whoever reads the dossier, and prose about it is output the next model pays for and cannot act on.

Never, at any point in this skill:

- edit, create, rename, or delete a file
- run a command that writes — formatters, codemods, agents, installs, migrations, `git commit`, `git stash`
- experiment with a speculative fix to see whether it works

The moment you catch yourself forming a patch, you have finished assessing. Write its description into the dossier instead of applying it. Code changes belong to the next phase, not this one.

## The pass

### 1. Take the report

The user's argument is the bug report. Reduce it to two lines: the **symptom** (what is observed) and the **expected** behaviour. Note the trigger — the input, action, or state that makes it happen — and keep any error text verbatim.

An empty or unusable argument is the one reason to interrupt: ask for the report and stop.

**Done when** symptom, expected, and trigger are each stated in a line.

### 2. Read the record

Before tracing code, read the most recent application logs. The project's `AGENTS.md` names where they live and how they rotate. A recorded stack trace, timestamp, or error string often names the fault outright, and a captured failure is frequently the exact input that reproduces the bug.

**Done when** you have either quoted the relevant log lines verbatim or established that no log covers the failure.

### 3. Locate

Recon by identifier, not by browsing. Search the error string, the names in the report, and the feature's vocabulary; read the entry points they land in. Follow the feature's own call path rather than reading the repository.

**Done when** you have a ranked shortlist of candidate files.

### 4. Trace to the fault

Follow the faulty value from the trigger to the wrong output, reading the bodies along that path. Read the surrounding code only as far as it bears on the value's journey.

**Done when** every hop on that path carries a `path:line`, and you can name the single line where behaviour first diverges from intent. That line is the **fault**, and it anchors the hypothesis.

### 5. Commit to one fault per symptom

The dossier names exactly one fault for each distinct observed symptom. A second candidate handed on as an equal passes the diagnosis to the next model at its price, and it will chase the wrong one first. A second *symptom*, though, is not a second candidate: when the report shows two different wrong outcomes — two states, two errors, on different items — trace each to its own fault, or you will hand on half the bug.

Tell them apart by the evidence: two symptoms whose log lines, recorded states, or error texts differ are separate unless one path demonstrably produces both.

When two candidates for the *same* symptom survive step 4, **discriminate** before writing: find the evidence only one of them explains — the exact error text, the recorded state, the log line, the symptom's wording. The fault is the candidate that produces the observed symptom exactly; a candidate that explains only part of it is a contributing cause at most.

- The winner goes under `Fault`, with the discriminating evidence as its confidence line.
- A disproved candidate goes under `Ruled out`, with what disproved it.
- A candidate you could not disprove goes under `Unknowns`, ranked below the fault, with the one check that would decide between them.

If no evidence separates them, `Fault` still names the likelier one at `confidence: medium` or lower, and `Unknowns` carries the deciding check.

**Fix what fails, not only how it got there.** When the fault is a guard that rejects missing or bad state, and you have found one way that state arises but cannot show it is the only one, say so in `Fault`. The fix must then hold at the guard as well — for rows or records already in that state — not only at the one source you found.

**Done when** `Fault` names one line per symptom, each tied to the symptom it explains, and every other candidate sits in `Ruled out` or `Unknowns`.

### 6. Note the fixer's conventions

The next model implements the fix in this repo's style and proves it with this repo's tests. Record what you already saw that governs that work, so it does not pay to rediscover it:

- the style guide and testing docs `AGENTS.md` points to, each with the one or two rules the fix will touch
- the existing test file that covers the faulty module, if any
- the exact command that runs those tests

Pointers and rules only; the docs themselves stay out.

**Done when** `Conventions` names the test command, or states that none exists.

### 7. Compress into the dossier

Write the dossier as the block below. It is a budget, not a form: the next model pays for every line, and a dossier read by someone who has never seen this repo should let them implement the fix without opening another file.

````text
<!-- ASSESS-DOSSIER:BEGIN -->

## Root
<absolute directory every path below is relative to>
- <repo dir> — branch <name> @ <short commit>, <clean | uncommitted changes>

## Symptom
<observed, expected, trigger — one line each>

## Fault
<path:line — the line that diverges> (one entry per symptom; prefix each with the symptom it explains when there is more than one)
<one-paragraph root cause hypothesis>
<confidence: high | medium | low — and the discriminating evidence that carries it>

## Paths
- `path/to/file.ext:120-148` — what this file owes the fix
- `path/to/other.ext:12` — and this one

## Exhibits
`path/to/file.ext:120-148`
```<lang>
<verbatim, trimmed to the smallest window that still reads as the real code>
```

`path/to/other.ext:8-14`
```<lang>
<verbatim>
```

## Ruled out
- <candidate cause — the line or command that disproved it>

## Unknowns
- <what you could not confirm from reading alone>

## Conventions
- <doc path> — <the rule from it the fix must honour>
- tests: <existing test file for the faulty module>
- run: <exact test command>

<!-- ASSESS-DOSSIER:END -->
````

Keep the section titles and sentinels exactly as written — the next phase reads them.

**What earns a place.** Paths the fix must change; signatures it must match; the branch condition that misbehaves; the wrong value as *actual vs expected*; error text verbatim; the call chain, once.

**Paths are relative to `Root`.** `Root` records where you read and at which commit, so a reader in another worktree or branch knows when the exhibits no longer describe its files. Read the branch and commit with `git -C <repo> rev-parse --abbrev-ref HEAD` and `git -C <repo> rev-parse --short HEAD`; `git -C <repo> status --porcelain` tells clean from uncommitted. List every repo a path lives in.

**What stays out.** Build and lint config, unrelated modules, dependency trees, conventions beyond the rules the fix touches, tests that do not exercise the fault, and the story of your own search. Do not narrate; conclude.

**Exhibits are verbatim.** Never retype from memory and never paraphrase. Trim to the enclosing signature plus the fault; a reader must be able to compile the snippet mentally without opening the file.

Typical dossiers run 50–130 lines. Past that you are keeping context, not evidence.

**Done when** the dossier is complete, every path in it exists, and every exhibit matches the file it came from.

### 8. Hand off

Close with this line, exactly:

> Assessment complete. Context is ready for `/route-context`.

With that line the read-only constraint ends: the next phase owns the code, and any urge you still feel to patch something belongs there.