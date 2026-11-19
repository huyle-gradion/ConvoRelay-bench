# Filter balance and list by tag

To see what was spent on food I export the ledger and sum the `#food` lines by hand. `tl balance` and
`tl list` should take `--tag NAME` and look at the entries with that tag only.

Touches: internal/cli/, ledger/

## Decisions

- A tag matches exactly: `--tag Food` does not match `#food`.
- `tl tags` is not changed.

## Acceptance criteria

- Given entries tagged food (-3.50 and -9.00), gift (5.00) and one without a tag (7.00), when `tl balance --tag food` runs, then it prints `-12.50` and exits 0
- Given the same entries, when `tl balance --tag nothing` runs, then it prints `0.00` and exits 0
- Given the same entries, when `tl list --tag food` runs, then it prints only the two food entries, in file order, in the usual list format
- Given entries tagged `food`, when `tl balance --tag Food` runs, then it prints `0.00`: tags are case-sensitive
