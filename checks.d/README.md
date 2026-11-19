# checks.d: more checks for the scorer

`lib/score.sh` runs every executable `NN-name.sh` in this directory after `bench-unit` and `hidden-acceptance`,
in name order, as `NN-name.sh TASK CHECKOUT`. `CHECKOUT` is the fresh checkout of the arm's result commit
with the task's hidden tests in it. Exit 0 is a pass; the last line printed is the reason. Each hook is
reported as one FactoryBench `gate` event named `name` and appears in the result's `checks`.

**The mutation gate goes here** as `50-mutation.sh` (the product's mutation tool run over the files the
result commit changed, passing only when enough mutants die). It does not exist yet: nothing in this
directory pretends to be it, and a result without it has no `mutation` check.
