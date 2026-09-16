# Output contract

For a source file named `<spec_name>.md`, use this layout:

```text
<spec_name>_impl/
├── README.md
├── task_01_<brief_name>.md
├── task_02_<brief_name>.md
└── ...
```

Replace every angle-bracket placeholder with feature-specific content. Preserve all headings, metadata labels, checkbox syntax, and the italicized testing instruction. Add or remove task rows, task links, implementation points, and acceptance criteria as the feature requires, while retaining the same structure. Use actual prerequisite task numbers in place of `X` and `Y`.

## Master index: `<spec_name>_impl/README.md`

```markdown
# <Feature Name> implementation

Source of truth: [<Specification Document Title>](../<spec_name>.md).
The specification owns product behavior, document fields, identities, indexes,
and accepted limitations. This plan breaks that scope into verifiable tasks.

## Implementation order and working rules

- Read the applicable repository `AGENTS.md` and area guides before implementation.
- Use TDD for behavioral changes: record the expected failing test, implement, and verify it passes.
- Do not run repository-wide or full test suites. Run only the focused, targeted tests required to verify the immediate acceptance criteria of the current task.

Tasks <X> and <Y> are mandatory prerequisites. Complete and verify both before
starting any feature implementation task, including allowance-only work.
The numbered order below is a workable delivery sequence; explicit dependencies
also identify which completed foundations each task requires.

| Implemented | Task | Deliverable              | Depends on |
| ----------- | ---- | ------------------------ | ---------- |
| [ ]         | 1    | <Brief Deliverable Name> | None       |
| [ ]         | 2    | <Brief Deliverable Name> | 1          |
| [ ]         | 3    | <Brief Deliverable Name> | 1, 2       |

## Task files

1. [<Brief Deliverable Name>](task_01_<brief_name>.md)
2. [<Brief Deliverable Name>](task_02_<brief_name>.md)
3. [<Brief Deliverable Name>](task_03_<brief_name>.md)
```

`X` and `Y` must identify the two actual foundation tasks that gate feature implementation. If the specification genuinely has fewer than two foundation tasks, keep the sentence structurally intact and name only the genuine prerequisite task or tasks; never manufacture work merely to fill the template.

## Task file: `<spec_name>_impl/task_<NN>_<brief_name>.md`

Create one file for every index row:

```markdown
# Task <N> — <Task Name>

**Index:** [Implementation Plan](./README.md)\
**Status:** Pending\
**Depends on:** <List previous tasks by number, or "None">\
**Specification:** `../<spec_name>.md` *(Read ONLY the sections: "<Section A>", "<Section B>")*

## Goal

<One or two sentences summarizing the precise atomic objective.>

## Implementation points

- [ ] <Execution instruction focusing on exact module reuse and architectural boundaries>
- [ ] <Execution instruction enforcing specific data types, schemas, or algorithms>
- [ ] <Execution instruction containing strict negative constraints and the approved alternative>
- [ ] <Execution instruction defining idempotency or state-change rules>

## Tests and acceptance criteria

*Write and run ONLY focused, targeted tests (avoid repository-wide test suites) using the project's standard testing framework to verify:*

- [ ] <Observable behavior, such as identical payloads causing no update>
- [ ] <Data integrity, such as serialization preserving exact monetary meaning without float precision loss>
- [ ] <Error isolation, such as a downstream exception leaving committed local work successful>
- [ ] <Data routing, such as the environment/account matrix routing and filtering correctly>
```

Use as many checklist items as the task needs for complete, unambiguous execution. Omit an inapplicable category rather than inventing behavior, but always include at least one implementation point covering reuse/boundaries, one hard guardrail where a plausible wrong turn exists, and focused acceptance criteria that prove the goal.

## Response framing

Return only the deliverable files, in this order:

1. A plain-text filepath such as `<spec_name>_impl/README.md`.
2. A fenced `markdown` block containing that file's complete contents.
3. Each task filepath and complete fenced contents in ascending task order.

Do not replace file contents with excerpts, ellipses, commentary, or a summary.
