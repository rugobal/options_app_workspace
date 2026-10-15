---
name: tasks
description: Turn a spec into an indexed directory of atomic, AI-executable implementation task documents. Use when a user provides or points to a feature spec and wants an implementation plan split into isolated task files; do not use for issue-tracker tickets or direct implementation.
---

# Tasks

Convert one spec into a dependency-ordered implementation plan that an autonomous coding agent can execute across fresh sessions.

## Workflow

1. Read the complete source specification yourself. Resolve its title and filename stem, and inventory every requirement, constraint, accepted limitation, identity, schema, index, and observable behavior.
2. Read the applicable repository `AGENTS.md` files and inspect only enough of the codebase to ground the plan in real modules, clients, types, tests, and architectural patterns. Use exact existing paths and symbols when known; never invent reusable components. When the specification introduces or changes module interfaces, seams, or responsibilities, read the `codebase-design` skill if available and use its guidance to clarify design decisions implementation tasks must preserve. Keep redesign work grounded in the specification and codebase.
3. Partition the work into atomic tasks sized for one fresh coding-agent session. Give each task one coherent, independently verifiable outcome. Put foundations before their consumers and declare only genuine dependencies.
4. Map every task to the smallest sufficient set of specification section headings. A task must direct its implementer to read only those named sections, never the entire specification.
5. Make every task execution-ready:
   - Name the existing modules, clients, seams, or patterns to reuse.
   - Fix required data types, serialization formats, schema versions, algorithms, and error boundaries wherever the specification decides them.
   - Pair hard negative constraints with the intended positive path, so the implementer knows both the boundary and the approved approach.
   - Define idempotency and state-transition behavior when the task can mutate state.
   - Use observable, focused acceptance criteria and the repository's standard test framework.
   - Assign a **Risk** level, which sets the implementer's model tier. `High`: the task changes trade lifecycle state (entry, monitoring, exits, recovery), broker orders or events, state shared across threads, or money and price calculations. `Low`: it follows an existing pattern and touches none of those (docs, copy, wiring, a view or test modelled on a neighbour). `Normal`: everything else. When torn between two levels, take the higher, and give the deciding reason in a few words.
6. Audit the plan before returning it. Every in-scope requirement must be owned by at least one task; every task must trace to the exact relevant spec sections; filenames, numbering, links, dependency rows, and task headers must agree; every task carries a Risk level. Remove speculative work and requirements not grounded in the specification or repository.
7. Read [the output contract](references/output-contract.md), then return the complete `README.md` followed by every task file in numeric order. Mark each filepath immediately before its fenced Markdown block. When the user explicitly asks to save the files, create the same directory and contents instead of merely displaying them.

## Planning boundaries

- Treat the specification as the source of truth for product behavior. Surface a real ambiguity instead of silently deciding product behavior.
- Use two-digit task filenames (`task_01_...`, `task_02_...`) and lowercase snake_case brief names.
- Preserve exact specification heading text in each task's `Specification` pointer.
- Keep each task self-contained. Include the context needed for that task, but do not duplicate the whole specification or unrelated task instructions.
- Keep tests proportional to the task. Require focused tests only; repository-wide and full-suite commands are outside every task's scope.
- Produce implementation documents, not implementation code, issue-tracker tickets, or a prose summary.
