# Let t12-queue start tasks of different products side by side

`t12-queue` treats a run or a task with no `touches` as touching everything, so two tasks that name
different products never run in parallel unless each also lists `touches`. The profile already says which
product owns which paths, and a task names its `product`: tasks of different products cannot collide, so
the queue should know that without `touches`. This is the first item under "Not done" in REWRITE-LOG.md
(Products and Asana-only intake).

Touches: factory/internal/queue/queue.go

## Decisions

- A run's `product` comes from its run record, a task's from its task file; either may be missing.
- When either side has no product, nothing changes: the old rules decide.
- `touches` keep deciding between two tasks of the same product.

## Acceptance criteria

- Given a run of product `alpha` that has no `touches` and a queued task of product `beta` that has none, when the queue passes, then the task starts
- Given the same run and a queued task of product `alpha` with no `touches`, when the queue passes, then the task waits because its touches overlap the run
- Given two queued tasks, one of product `alpha` and one of product `beta`, both without `touches`, and no runs, when the queue passes with room for both, then both start
- Given a run of product `alpha` with no `touches` and a queued task of product `beta` with `touches` of `src/x`, when the queue passes, then the task starts
- Given a run of product `alpha` and a queued task that names no product and no `touches`, when the queue passes, then the task waits
