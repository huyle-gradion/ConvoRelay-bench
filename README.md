# ConvoRelay-bench: turbo-12f against a baseline factory

## Where this lives

This repository was `factory/bench/` of ConvoRelay, with the sub-task breakdown of US-S1-01
(`docs/product/breakdown/US-S1-01/` there) now in [`breakdown/US-S1-01/`](breakdown/US-S1-01). It is a repository of its own so
that the benchmark, its hidden tests and its reference patches never ride along in the repository the arms
work on. It benchmarks a ConvoRelay checkout, which `CONVORELAY_DIR` names (default: `../ConvoRelay`, the
sibling of this repository; it must be a git repository with `factory/go.mod`, else the scripts stop and say
so): the t12 programs are built from its `factory/` module, and every task and chain base (`tasks/*/product`,
`order.json`'s `base`) is a ConvoRelay commit that `git archive` reads from it, so those hashes are ConvoRelay
history, not this repository's. Run the scripts from anywhere inside this repository, for example
`CONVORELAY_DIR=~/src/ConvoRelay ./run.sh --arm t12 --task tl-crlf --yes`. Every path below is relative to
the root of this repository.

Every factory feature must beat a baseline factory (ConvoRelay's `factory/GLOSSARY.md`) on a benchmark or be deleted (the hash
chain and the blob locks are constraints, not features). This repository is that benchmark: two arms
work the same tasks, both report to [FactoryBench](https://github.com/huyle-gradion/Factory-Bench), and one
deterministic checker scores both.

| Arm | What runs | Lanes |
|---|---|---|
| `t12` | turbo-12f's pipeline through `bin/t12-runner`: analyzer, red, green, refactor, final (with its mutation check), QC (static, verification, `reviewer-bugs`, `reviewer-quality`) | off: every `task.json` has `max_lanes: 1`, and `arm-t12.sh` refuses a task that says otherwise |
| `t12-deep` | the arm `t12` with one deep Engineer session in place of the analyzer, red, green and refactor (`"engineer": "deep"` is added to the queued `task.json`; QC, review and everything else are the same) | off, as for `t12` |
| `baseline` | ONE Claude Code session (`claude -p`) per task with the WHOLE pstack loaded, started with `/pstack:poteto-mode` and the issue text (decision D4) | n/a |

Lanes are frozen and never part of a comparison (D3).

## Held equal

The comparison is only about the factory, so everything else is the same on both arms (D4, D14):

| | t12 | baseline |
|---|---|---|
| worker model | `claude-sonnet-5-5`, `--omp-model anthropic/claude-sonnet-5-5` | `claude-sonnet-5-5`, `claude --model` |
| worker thinking | omp's profile default (no `--thinking`) | Claude Code's default |
| t12's own reviewer roles | Claude Opus 5.5, medium, for both `reviewer-bugs` and `reviewer-quality`: `--role-model reviewer-bugs=anthropic/claude-opus-5-5 --role-thinking reviewer-bugs=medium` and the same for `reviewer-quality` | not applicable |
| the shared review of the final diff | the same two sessions | the same two sessions |
| the checks | `bench-unit`, `hidden-acceptance`, `review` by `lib/score.sh` | same |
| the task text | `issue.md` through the intake's `task.json` | `issue.md` |

The reviewers are constants in `lib/common.sh`, not flags. The **shared review** (`lib/review.sh`, run by the
checker on each arm's final diff, `pstack.pin` pins its skills) is two read-only Claude Code sessions
in parallel on Claude Opus 5.5 with medium thinking (`--effort medium`):

1. bugs and security: `/pstack:thermo-nuclear-review`;
2. quality: `/pstack:thermo-nuclear-code-quality-review` and the `ponytail-review` skill.

A session may read files and run `git diff|log|show|status|ls-files|blame`; it cannot edit, write, run tests or
start a subagent. It reviews a fresh clone of the result commit without the hidden tests. The verdict is
`approve` only when both end with `VERDICT: approve`. A session that fails, runs out of its budget
(`BENCH_REVIEW_MAX_COST`, $2) or gives no verdict line is `unavailable` and fails the check: QC stays closed
when a reviewer cannot run (D14). The check is the gate `bench:review` on the arm's attempt, and the verdicts,
cost and both transcripts are kept in `<run>/<task>/<arm>/review/` and in `results.jsonl`.

**The baseline's pstack** is the plugin `pstack-claude` (the Claude Code port of
[pstack](https://github.com/cursor/plugins/tree/main/pstack), as `/plugin install pstack@pstack-claude`
installs it) at the revision in `pstack.pin`, version 0.9.135. `lib/skills.sh` builds
`plugins/pstack` of that commit with `git archive` into `.pstack/<rev>` (from `~/.agents/pstack-claude` or
`BENCH_PSTACK_REPO` when one has the commit, else fetched from GitHub; never from a working copy) and refuses to
go on unless the tree's sha256 equals the pin. The session loads it with `--plugin-dir` and
`--setting-sources project`, so your own user plugins and skills stay out. The factory config version reported
to FactoryBench is `claude-code@<version>+<model>+pstack-claude@<rev>+tree-sha256:<hash>+bench-baseline`.
`arm-baseline.sh` checks the session's `init` line and marks the run `invalid` when `pstack:poteto-mode` is
not among its slash commands. pstack routes its own subagents by its `models.json` (Opus for judgment, Sonnet
for features), so the baseline spends some Opus time on its own; that is the stack as designed, not a leak
of a different model into the worker.

`ponytail-review` is not in pstack: it is the user skill `~/.agents/skills/ponytail-review/SKILL.md`
(`BENCH_PONYTAIL_REVIEW=PATH` for another place), pinned by its sha256 in `pstack.pin` and loaded as a
one-skill plugin.

## Run it

```sh
# once: a FactoryBench with one factory per arm (each token is shown once)
factorybench factory add bench-t12      --commit-email t12-bot@users.noreply.github.com
factorybench factory add bench-t12-deep --commit-email t12-deep-bot@users.noreply.github.com   # only for the t12-deep arm
factorybench factory add bench-baseline --commit-email baseline-bot@users.noreply.github.com
factorybench serve --addr 127.0.0.1:8080          # no --poll: the work items are not GitHub issues

export FACTORYBENCH_URL=http://127.0.0.1:8080
export FACTORYBENCH_TOKEN_T12=fbt_...             # bench-t12's token
export FACTORYBENCH_TOKEN_T12_DEEP=fbt_...        # bench-t12-deep's token (may equal the t12 one: the deep attempts still carry "+engineer:deep" in their factory_config_version)
export FACTORYBENCH_TOKEN_BASELINE=fbt_...        # bench-baseline's token

./dry-run.sh                                  # first, for free: both arms against fakes

# the paid comparison, one task first (about $5 for both arms with their reviews, see below)
./run.sh --arm t12      --task tl-crlf --yes
./run.sh --arm baseline --task tl-crlf --yes
./run.sh --arm t12-deep --task tl-crlf --yes     # the deep Engineer, same pipeline after it
# then the rest, same model on both arms
./run.sh --arm t12      --task all --yes --model claude-sonnet-5-5
./run.sh --arm baseline --task all --yes --model claude-sonnet-5-5
factorybench report items --factory bench-t12
factorybench report items --factory bench-baseline
```

The script finds its own directory, so run it from anywhere. Without `FACTORYBENCH_URL` nothing is reported,
but the arms still run and `.runs/<stamp>/results.jsonl` still records the checks. Without `--yes` the
script stops after printing what it would do. `--help` lists every flag. Run the two arms one after the other
on a machine with nothing else running.

**Cost warning.** A real run calls paid models, and the review adds two Opus sessions to every scored run
of either arm. Everything below is an `[INFERENCE]`: the one measured number is `DESIGN.md`'s $1.71 and about
8 minutes for one toy task through t12 (`text-serial`: 44 sessions, the reviewer on opus a third of it); the
prices ($ per million tokens: Sonnet 5.5 2 in, 10 out, 0.1 cache read, 2.5 cache write; Opus 5.5 4, 20,
0.2, 5) are those of omp's model catalog, and the sizes are guessed from the task sizes below.

| Per task, mid [low to high] | t12 | baseline (whole pstack) | shared review, per arm |
|---|---|---|---|
| XS `tl-crlf` | 1.0 [0.7 to 1.5] | 1.0 [0.5 to 1.5] | 0.9 [0.6 to 1.3] |
| S `tl-date`, `tl-tags-order` | 1.5 [1.0 to 2.2] | 2.5 [1.5 to 4] | 1.1 [0.8 to 1.5] |
| M `tl-tag-filter`, `tl-summary` | 2.2 [1.5 to 3] | 5 [3 to 8] | 1.3 [0.9 to 1.8] |
| S factory `fac-version`, `fac-queue-product` | 3.5 [2.5 to 5] | 3.5 [2 to 5] | 1.8 [1.2 to 2.5] |
| M factory `fac-context-docs` | 5 [3.5 to 7] | 7 [4 to 10] | 2.2 [1.5 to 3] |

| Totals, USD | t12 | baseline | both arms |
|---|---|---|---|
| the arm itself, 8 tasks | about 20 [14 to 29] | about 30 [18 to 46] | about 50 [32 to 74] |
| the shared review, 8 tasks | about 11.5 [8 to 16] | about 11.5 [8 to 16] | about 23 [16 to 32] |
| **8 tasks, arm and review** | **about 32 [22 to 45]** | **about 41 [25 to 61]** | **about 73 [47 to 106]** |
| the 5 tinyledger tasks, arm and review | about 14 [10 to 20] | about 22 [14 to 33] | about 36 [24 to 53] |
| `tl-crlf` alone, arm and review | about 1.9 [1.3 to 2.8] | about 1.9 [1.1 to 2.8] | about 3.8 [2.4 to 5.6] |

The baseline costs more than a plain Sonnet session because `/poteto-mode` reads its own skill and playbooks
(about 15 to 40 KB of prompt), fans out `how`, `architect`, subagents and checks, and routes judgment to Opus;
a one-line fix stays cheap (`tl-crlf`), a feature does not. Wall time: t12 about 8 minutes per small task
(DESIGN.md), 2 to 3 hours for 8; the baseline 3 to 15 minutes per task, plus about 3 minutes per task for the
reviews. On this estimate a pass over all 8 tasks on both arms costs about **twice** a $20 to 40 budget; the
5 tinyledger tasks on both arms fit inside it at mid (about $36; $24 low, $53 high), so start with them
and decide on the factory tasks after you have seen the real numbers of `tl-crlf`.

`--max-cost USD` caps ONE model session: each of t12's ~40 sessions per task (default 3), or the baseline's
single session (default 6); `BENCH_REVIEW_MAX_COST` (default 2) caps each review session. The baseline's
spend per task is therefore at most $6 plus $4 of reviews, $80 over 8 tasks, if the cap counts the pstack
subagents of that session (not verified); t12's per-session cap gives no per-task bound, so watch the first
task with `factorybench report items`. Delete `.runs/` and `.pstack/` when you are done.

Prerequisites: Go 1.27, `jq`, `git`, `factorybench`; for the t12 arm `omp` with its `t12-worker` profile
logged in (`README.md`) and the t12 programs (the script builds `go -C factory build -o bin/ ./cmd/...`
unless `T12_BIN` is set); for the baseline and the reviews `claude` (2.1.292 or later, for plugins) logged in.
The factory tasks run on the product at `5358c53`, whose profile still has the integration and guard gates
of that commit, so `bun` must be on `PATH` too (its install directory goes into `T12_TOOLCHAIN_DIRS` for the cage;
`BENCH_TOOLCHAIN_DIRS` overrides). The cage builds into `$TMPDIR/t12-<home>-<task>`, and a cold Go build there
writes a few hundred MB: where `/tmp` is a small or quota-limited tmpfs, `prepare` fails with `disk quota
exceeded`. Point `TMPDIR` at a bigger filesystem for the run.

### Without paying

`dry-run.sh` runs both arms with fakes (ConvoRelay `factory/tests/support`'s fake omp and model, and a fake `claude` that is
put first on `PATH` before anything else runs and stands in for the baseline session AND the reviewers)
against a throwaway FactoryBench on a loopback port. It prints `factorybench report items`, `report item` and
`report factories`, then checks what the fakes were given and fails if any of it is wrong: the baseline's
prompt starts with `/pstack:poteto-mode` and the pinned pstack is the one plugin, with all its skills, on
`--setting-sources project`; both reviewers are read-only Opus 5.5 medium sessions on a checkout without the
hidden tests; t12's omp sessions have sonnet for the workers and Opus 5.5 medium for the reviewer; every task
says `max_lanes: 1`; and a `changes` verdict or a missing commit fails the run's review. Then it kills the
server and deletes every temporary file. `prove.sh [--task ID|all]` proves the tasks (below) without
the review.

## The tasks

| Task | Product | Size | Hidden tests | What it asks |
|---|---|---|---|---|
| `fac-version` | factory @ `5358c53` | S, 3 files | 4 | the real Asana sub-task: `t12 version` and `t12 --version` |
| `fac-queue-product` | factory @ `5358c53` | S, 1 file | 3 | `t12-queue` starts tasks of different products side by side (`factory/REWRITE-LOG.md` "Not done" in ConvoRelay) |
| `fac-context-docs` | factory @ `5358c53` | M, 3 files | 4 | the profile key `context_docs` (ConvoRelay `docs/generic-factory.md`: "Not built yet") |
| `tl-crlf` | tinyledger | XS, 1-line fix | 3 | a ledger with `\r\n` line endings fails to load |
| `tl-date` | tinyledger | S, 1 file | 3 | refuse dates that do not exist |
| `tl-tag-filter` | tinyledger | M, 2 files | 4 | `--tag NAME` for `balance` and `list` |
| `tl-tags-order` | tinyledger | S, refactor-safe | 3 | `tl tags` prints in a fixed order (the existing tests must stay green) |
| `tl-summary` | tinyledger | M, 2 files | 4 | a new `tl summary` command |

`tinyledger` (`products/tinyledger`, about 380 lines with its tests, its own `.t12/project.json`: a
unit tier and `go vet` as lint, and a minimal `.claude/skills/verify`, without which `t12 prepare` refuses the
product) is a plain-text ledger library with a small CLI. The factory is the product at
commit `5358c53`, the whole repository, because that is where its profile lives.

A task is a directory `tasks/<id>/`:

| File | Who sees it |
|---|---|
| `issue.md` | both arms: the title, a summary, a `Touches:` line and Given/When/Then acceptance criteria, in the format ConvoRelay's `factory/docs/spec-standard.md` asks of an issue |
| `task.json` | t12: the task file an intake adapter would build from `issue.md` (title, criteria, touches, `source`, `max_lanes: 1`; the intake drops the summary too). Its `source.ref` is `bench/<product>#<n>`, which is what makes the runner report an attempt to FactoryBench |
| `product` | the harness: `<product> <base>`: `5358c53` for the factory, `tree` for a product under `products` |
| `hidden/` | nobody but the checker: acceptance tests laid out like the product (`hidden/factory/tests/acceptance/...`) |
| `reference.patch` | nobody: a solution, to prove the hidden tests can pass |

`products.json` says, per product, how its base is made and which commands are its unit tier and its
hidden tests.

### How the tests stay hidden

- The product repository an arm gets is a fresh `git init` with ONE commit made from the base tree
  (`git archive` of `5358c53` from `CONVORELAY_DIR`, or a copy of `products/<name>`). It carries no history of
  ConvoRelay or of this repository, so no object, branch or stash in it holds `hidden/` or a `reference.patch`.
- `hidden/` stays under `tasks/<id>/`, outside that checkout, until `lib/score.sh` copies it into a
  fresh clone of the arm's result commit. The tests are `TestHidden*` in files called `zz_hidden_*_test.go`,
  so they cannot collide with what an arm writes.
- `run.sh` makes the arm's working directory (`<out>/<stamp>/<task>/<arm>/product`) first, runs the arm in
  it, and only afterwards lets `score.sh` copy `hidden/` into its own checkout in a temporary directory. The
  hidden tests are never under the arm's working directory at any time the arm runs (`score.sh` refuses a
  scoring directory inside the arm's repository).
- t12's workers run in the cage, which cannot read this directory.
- `tasks/go.mod` makes the tasks tree a Go module of its own, so a `go vet ./...` or `go test ./...` run from
  this repository never compiles hidden tests that only make sense inside their product.
- **Baseline isolation caveat.** The baseline's Claude Code runs unsandboxed: its `Read` and `Edit` tools stop
  at the checkout, but its `Bash` tool can `find` its way to `tasks`, where `hidden/` and
  `reference.patch` live (and to `.pstack`, which is harmless). Nothing in the prompt names that path, but
  nothing stops it. For any result you intend to trust, **run the baseline as a user who cannot read this
  repository**. `run.sh` does not switch users: give that user a copy of this repository without `tasks/*/hidden` and
  `reference.patch`, run the baseline pass there with `--no-score`, then score the result commits yourself with
  `lib/score.sh --task ID --repo <work>/product --commit <arm.json commit>`. The review sessions need no such
  care: they run in a clone without the hidden tests and may only read files and run `git` reads.

## What is measured

- **FactoryBench** gets each attempt's tokens, cost, wall time (`attempt.started` to `attempt.finished`),
  human waits and the factory's own gates. t12 reports them itself (ConvoRelay `factory/internal/adapters/fbreport`); the
  baseline script sends `attempt.started`, one `usage` per model from the stream-json `result` line (through
  `factorybench claude-translate`) and `attempt.finished`. This FactoryBench has no OTLP intake, so no OTLP
  is sent. Attempt ids are `t12-<uuid>` and `cc-<time>-<pid>`.
- **The checker**, `lib/score.sh`, runs on the result commit of either arm, in a fresh clone, with no network
  for the tests:
  1. `bench-unit`: the product's unit tier as the arm left it.
  2. `hidden-acceptance`: the task's hidden tests copied over the clone, then run. It passes only when the
     command exits 0 and every `TestHidden*` function of the task ran and passed, so a run that found no
     test cannot pass.
  3. `review`: the shared review (see "Held equal"), the only check that calls a model. `--no-review` leaves
     it out (`prove.sh` does).
  4. any executable in `checks.d/` (none yet).

  Each check is one FactoryBench `gate` event on the arm's attempt, named `bench-unit`, `hidden-acceptance`
  or `review`, with the key `bench:<name>`. The unit gate is called `bench-unit` so that it never mixes with
  the gate events of t12's own static and verification checks (key `gate:<n>`) in the scorecard's "Gates (defects caught)" rows. A run `passed` when
  every check did, the review included; its verdicts and cost are in `results.jsonl` under `review`.
- **Wall time** goes in `results.jsonl` as `wall_s`: from the moment the arm starts to the moment it exits.
  For t12 that includes `t12 prepare`, which for the factory product runs the unit tier once on the base to
  time it; for the baseline it is the one session. Making the product
  repository and the scoring are outside it.
- **The result commit** of t12 is the candidate it pinned at `final` (or the branch tip when it never got
  there); of the baseline, `HEAD` after committing whatever the session left in the working tree. An arm
  that left nothing fails every check with the reason "no result commit".

The checker's mutation check is not built (the factory's own runs one inside `final`). Its place is `checks.d/50-mutation.sh` (see `checks.d/README.md`): the
scorer runs every executable there after the built-in checks and reports each as a gate. Until one exists,
`results.jsonl` lists only the checks that ran.

## Proving the tasks

`prove.sh` scores the untouched base and the base plus `reference.patch` for each task, with the same
checker, and fails unless

- `task.json` says what `issue.md` says, and `t12-adapter spec-check` accepts `issue.md`;
- on the base the unit tier passes and EVERY hidden test fails (`0/N`, not just "the package fails");
- on the reference both the unit tier and every hidden test pass.

The `fac-context-docs` tests read `Profile.ContextDocs` by reflection so that the base fails them one by one
and not by a compile error that would hide the rest.

## Chains: one product repository, tasks that build on each other

A task above starts from a fresh repository. A **chain** (`chains/<chain>/`) runs the tasks of one user story,
in order, on ONE repository per arm: each task that reaches `local-verified` is merged into `main` (the human
merge, by fast-forward) before the next one starts, so a later task builds on what the arm itself wrote. It compares
the two Engineers (D32): `t12` (tdd) against `t12-deep`, everything else equal, on real product work. The chain
`us-s1-01` is the story US-S1-01 (ChatBridge: Fake Source and Mock Margince) on the Node/TypeScript skeleton
`chatbridge/` (D33: the Margince side runs against the stand-in contract in `chatbridge/contract/margince/`, so it
compares the arms fairly and proves nothing about real Margince). Eight tasks, S2-D having been folded into the
hidden tests of S2-C:

| # | Task | Hidden tests | Depends on | Touches |
|---|---|---|---|---|
| 1 | `S1-A` Load a Fake Source fixture file | 43 | | `src/fake/fixture.ts` |
| 2 | `S1-B` Standard fixture covering every message kind | 11 | S1-A | `fixtures/fake/standard.jsonl` |
| 3 | `S1-C` Replay fixture events at a configured speed | 22 | S1-A | `src/fake/replay.ts` |
| 4 | `S1-D` `chat-bridge run --fake <fixture>` | 17 | S1-C | `src/cli/main.ts`, `run.ts` |
| 5 | `S2-A` Sign and verify Margince requests | 19 | | `src/margince/signature.ts` |
| 6 | `S2-B` Mock Margince validates signed batches | 28 | S2-A | `src/mock-margince/handler.ts` |
| 7 | `S2-C` Mock Margince enforces Margince's rate limits (and replays every recorded pair) | 20 | S2-B | `ratelimit.ts`, `handler.ts` |
| 8 | `S2-E` `chat-bridge mock-margince` command | 21 | S2-B | `src/cli/main.ts`, `mock-margince.ts` |

```sh
./prove-chain.sh                                   # free: the base fails every hidden test set, the reference passes all 8 in order
./chain-dry-run.sh                                 # free: both arms over the first two tasks with the fake omp (see below)
./chain.sh --arm t12      --chain us-s1-01 --yes   # paid, one arm after the other, nothing else running
./chain.sh --arm t12-deep --chain us-s1-01 --yes
```

`chain.sh --help` lists every flag. Prerequisites beyond the ones below: node 22.18 or later (`BENCH_NODE`), `npm` with a warm cache
(or `BENCH_NODE_MODULES`), `sqlite3` for the cost column. What it does:

1. **One product repository per arm**, `<run>/product`: `git archive` of the chain's base commit (`order.json`'s
   `base`, `--base REV` for another) WITHOUT `factory/bench` (a base from before the move still holds it; this repository's tasks are not in ConvoRelay any more), made one `git init` commit (`lib/chain-common.sh`
   `chain_repo`, the way `product_repo` does it). The profile `.t12/project.json` is the repository's own, with the
   absolute node of this machine written into its argv and without `intake` and `delivery`: a bench repository has
   no Asana project and no forge to push to. `chatbridge/node_modules` comes from `npm ci --offline` (a warm npm
   cache) or is copied from `BENCH_NODE_MODULES=DIR`, so `verify_deps` exists; then `t12 init`. The cage gets
   `T12_TOOLCHAIN_DIRS=<node install dir>[:BENCH_TOOLCHAIN_DIRS]:<t12 bin>` (node comes from `BENCH_NODE` or
   `PATH`, resolved to the real install, not a shim).
2. **Per task, in order**: the task file (`chains/<chain>/<ID>/task.json`, with `"engineer": "deep"` on the arm
   `t12-deep`) goes into the queue directory and one `t12-queue` pass admits it through `t12 prepare`, so the
   queue's own `depends_on` check runs; an entry whose task did NOT merge is dropped from the queued file (the
   chain goes on from `main` as it is). The task's `node_modules` is copied into its worktree, as the profile
   notes ask of an operator (the factory does not for a Node product). `t12-runner` runs with the flags of
   `lib/arm-t12.sh` (workers on `--model`, reviewers Opus 5.5 medium, the skills cache, `--omp-max-cost`). A run
   that is `local-verified` has its candidate fast-forwarded into `main`; one that ends `paused` or `stopped` is
   stopped with `t12 stop` (so it holds no slot), recorded, and not merged.
3. **Score**, on a fresh clone of `main` as it is after that task: the product's unit tier (the whole suite, as
   `main` has it: pass/total), then the task's hidden tests (pass/expected). The hidden tests only enter this
   clone, never the arm's repository: `chains/<chain>/<ID>/hidden/*.test.ts` is copied to
   `chatbridge/src/zz-hidden/` and run with the product's own Vitest. Also recorded: wall time (queue pass plus
   runner, without the `node_modules` copy), the phase the run ended in, t12's own reviewers' last verdicts from the
   run's event log (`reviewed` events), and the cost FactoryBench priced for the attempt (the sum of `cost_usd` of
   its `usage` rows in `FB_DB`, default `~/.local/state/t12-bench/fb.db`; `-` when `FACTORYBENCH_URL` is unset).
   The runner reports the attempt itself (the tasks' `source.ref` is `bench/chatbridge#<n>`, `n` the place in the
   chain); `chain.sh` adds one `gate` event each for `bench-unit` and `hidden-acceptance`, as `lib/score.sh` does.
   There is no shared claude review in a chain, so a chain run calls no model but t12's own.
4. After the last task the whole chain's hidden tests run on the final `main`. `<run>/results.tsv` has one row per
   task (`n task arm phase merged wall_s unit_pass unit_total hidden_pass hidden_total hidden_expected reviews cost_usd
   attempt note`), `<run>/summary.txt` the table and the totals, and the run directory keeps every task's queue,
   runner and merge logs, run record, event log and score clone.

A chain directory holds `order.json` (the order, each task's `depends_on`, its hidden test count and the base
commit) and one directory per task: `task.json` (written by `build-tasks.sh` from the sub-task markdown in
`breakdown/US-S1-01/` the way the Asana intake builds it: title, criteria, `Touches:`, `Depends on:`,
`product: chatbridge`, `source`, `max_lanes: 1`; `build-tasks.sh --check` fails when one drifts), `hidden/<id>.test.ts`
(only the task's spec and the cited contract files were read to write it; every name starts with `hidden`; the module
under test is imported inside each test so a missing module fails that test, not the file; fake clocks, no sockets)
and `reference.patch` (the answer key, applied in chain order on the skeleton).

**Proving it.** `prove-chain.sh` builds the same product repository and, for each task in order, requires that its
hidden tests fail one by one (0 of N) on the skeleton AND on `main` with the earlier references applied, that N equals
`order.json`'s count, then applies the reference and requires the unit tier, `tsc`, ESLint and all N hidden tests to
pass, and every earlier task's hidden tests with them. `build-tasks.sh --check`, the `t12-adapter spec-check` of every
sub-task and the file rules (the patch touches only `chatbridge/`, `max_lanes` is 1) are checked too.

**Dry run.** `chain-dry-run.sh` runs `chain.sh` for both arms over the first two tasks (`--first N`) against a
throwaway FactoryBench, with ConvoRelay's `factory/tests/support` fake omp. Behind it, `testdata/fake-chain-model.sh` hands every role to
the Go toy's scripted fakemodel except the deep Engineer, which applies the task's reference patch. So `t12` cannot
solve a ChatBridge task (its red writes a Go test the product refuses): every task pauses, is stopped, and the chain
goes on from an unchanged `main`; `t12-deep` solves each task with the answer key, reaches `local-verified`, is
merged, and the next task is admitted with its `depends_on` met. The script checks the models the fake omp was
given, that neither product repository holds this bench (`factory/bench` of a pre-move base included), a hidden test or a reference patch, that FactoryBench
got an attempt and a cost for every task, and fails on any mismatch. It proves the runner, not either arm's quality.

**Cost warning** (all `[INFERENCE]`: scaled from the measured rows of the Engineer comparison in `log/redesign.md`,
D30: tinyledger tasks about $0.5 to 1.3 on `t12` and $0.35 to 0.45 on `t12-deep`, factory tasks about $1.8 to 3.5 and
$0.8; the chain's tasks are TypeScript, two to six criteria and a contract to read, so the upper half of those
ranges; t12's own Opus reviewers are in the numbers, there is no shared review). Per arm, the eight tasks:

| Per task, mid | S1-A | S1-B | S1-C | S1-D | S2-A | S2-B | S2-C | S2-E | 8 tasks, mid [low to high] |
|---|---|---|---|---|---|---|---|---|---|
| `t12` | 1.8 | 1.2 | 1.8 | 2.2 | 1.5 | 3.0 | 2.5 | 2.0 | **about $16 [11 to 24]** |
| `t12-deep` | 0.5 | 0.4 | 0.5 | 0.6 | 0.45 | 0.9 | 0.7 | 0.6 | **about $4.7 [3.3 to 7.5]** |

Both arms: about **$21 [14 to 32]**. Wall time: `t12` about 8 to 12 minutes a task, 1.2 to 1.6 hours for the chain
(a paused run costs its time and its money and moves nothing); `t12-deep` about 3 to 5 minutes a task, 30 to 40
minutes. `--max-cost` caps ONE worker session (default $3), so it bounds nothing per task: run `t12-deep` first
(cheap), watch `factorybench report items`, then `t12`. Delete `.runs/` when you are done.

## Reading a comparison

- Same tasks, same `--model`, one arm after the other on a machine with nothing else running: t12's tier
  timeouts and the wall time both depend on load.
- One run per task is an anecdote. Repeat the pass before you trust a difference, and compare the FactoryBench
  `factory_config_version`s, which change with the factory build, the omp version, the models, the profile and,
  for the baseline, the pstack revision.
- The thermo reviewers are strict by design. If both arms are `changes` everywhere the review separates
  nothing: read `review/*.md` and `results.jsonl` before you count verdicts.
- The goal metrics are issues delivered per day, revert rate and wall per issue. This benchmark measures the
  first and the third on a fixed task set, and the revert rate not at all.
