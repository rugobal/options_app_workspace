---
name: assess
description: Read-only reconnaissance of a bug, compressed into a dossier that a stronger model can fix from.
argument-hint: "The bug report: symptom, expected behaviour, and any error text."
disable-model-invocation: true
---

# Assess

`assess` is the cheap half of a two-model debugging pipeline. You recon the workspace and leave behind a **dossier**: everything a stronger model needs to write the fix, and nothing it does not.

The stronger model never sees this conversation. A context swap replaces it with the dossier alone, so **the dossier is your only deliverable**. Anything you understand but do not write down is lost, and anything you write down is paid for again by the next model.

## Your product is a dossier, not a diff

`assess` is a reconnaissance pass. You read; you never write.

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

### 2. Locate

Recon by identifier, not by browsing. Search the error string, the names in the report, and the feature's vocabulary; read the entry points they land in. Follow the feature's own call path rather than reading the repository.

**Done when** you have a ranked shortlist of candidate files.

### 3. Trace to the fault

Follow the faulty value from the trigger to the wrong output, reading the bodies along that path. Read the surrounding code only as far as it bears on the value's journey.

**Done when** every hop on that path carries a `path:line`, and you can name the single line where behaviour first diverges from intent. That line is the **fault**, and it anchors the hypothesis.

### 4. Compress into the dossier

Write the dossier as the block below. It is a budget, not a form: the next model pays for every line, and a dossier read by someone who has never seen this repo should let them implement the fix without opening another file.

````text
<!-- ASSESS-DOSSIER:BEGIN -->

## Symptom
<observed, expected, trigger — one line each>

## Fault
<path:line — the line that diverges>
<one-paragraph root cause hypothesis>
<confidence: high | medium | low — and the single piece of evidence that carries it>

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

<!-- ASSESS-DOSSIER:END -->
````

Keep the section titles and sentinels exactly as written — the next phase reads them.

**What earns a place.** Paths the fix must change; signatures it must match; the branch condition that misbehaves; the wrong value as *actual vs expected*; error text verbatim; the call chain, once.

**What stays out.** Build and lint config, unrelated modules, dependency trees, style conventions, tests that do not exercise the fault, and the story of your own search. Do not narrate; conclude.

**Exhibits are verbatim.** Never retype from memory and never paraphrase. Trim to the enclosing signature plus the fault; a reader must be able to compile the snippet mentally without opening the file.

Typical dossiers run 40–120 lines. Past that you are keeping context, not evidence.

**Done when** the dossier is complete, every path in it exists, and every exhibit matches the file it came from.

### 5. Hand off

Close with this line, exactly:

> Assessment complete. Context is ready for `/route-context`.

With that line the read-only constraint ends: the next phase owns the code, and any urge you still feel to patch something belongs there.