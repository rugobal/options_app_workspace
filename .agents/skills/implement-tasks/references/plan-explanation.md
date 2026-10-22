# Plan explanation

When a run completes a plan's last pending task, the plan's `README.md` gains two sections, written once for the whole plan, after the task table:

- `## Domain explanation`: what the plan's tasks built, as one story. The concept it touches, the new or changed behavior, and why it matters.
- `## Business scenario`: one concrete situation that shows the change. The ordinary situation that triggers the behavior, what went wrong or was missing before, and what happens now.

Write for a person who knows the business and not the code. Use the business terms from each repository's `domain.md`, in plain, concise language, and name no files, symbols, functions or code constructs. Build the story from the specification's own goal and scenario and from the tasks' verification sections, so it describes what was actually built, including any departure a user decided.

When the specification already tells a correct business scenario that this plan fully delivers, link it and add only what the implementation changed. Leave out `## Business scenario` only for purely internal work with no plausible scenario, and say so in the domain explanation.

These sections explain the business change; they are not a summary of the tasks. Model their tone and level of detail on these examples:

```markdown
## Domain explanation

The application already protects a trade when one of its short legs is stopped
out: the paired long leg is meant to be sold off, and the application records
that it still owes the sale when it cannot do it immediately. Until now that
record was only a standing alert — nothing in the application acted on it, so
the leftover long could stay open indefinitely unless a person noticed the
alert and intervened.

This plan closes that gap. The application now re-checks recorded leftovers on
its normal background cycle and, once it is safe to act, sells the leftover
long on its own, one clean-up at a time and without a human in the loop. A
leftover that can no longer be repaired is dropped, and a leftover that is not
yet safe to act on is kept for a later cycle.
```

```markdown
## Business scenario

The default iron condor is entered as two credit spreads — a short call paired
with a long call on the call side, and a short put paired with a long put on the
put side. The stop loss watches only the short legs, so when it fires the broker
closes just that short option and leaves the paired long option open.

Stop the short call in a rally, or the short put in a fall, and the trade is
effectively finished on that side while the lone long stays behind: its
protective purpose is gone, it still consumes buying power, and it leaves
residual risk the strategy no longer manages. When the template says to sell the
leftover long, the application must sell it. Before, that decision could be
recorded and then sit open until an operator noticed the alert; now the
application resumes the recorded repair by itself once the side is free, so the
long is closed with no person in the loop.
```
