# Add `tl summary`

I want one command that tells me how many entries a ledger has, what came in, what went out and what is
left, instead of reading `list` and `balance` side by side.

Touches: internal/cli/, ledger/

## Decisions

- `spent` is printed as a positive amount.
- An entry of 0.00 counts as an entry and adds to neither income nor spent.

## Acceptance criteria

- Given entries of 100.00, -3.50 and -1.25, when `tl summary` runs, then it prints the four lines `entries 3`, `income 100.00`, `spent 4.75` and `balance 95.25` and exits 0
- Given an empty ledger, when `tl summary` runs, then it prints `entries 0`, `income 0.00`, `spent 0.00` and `balance 0.00` and exits 0
- Given entries of 0.00 and 10.00, when `tl summary` runs, then it prints `entries 2`, `income 10.00`, `spent 0.00` and `balance 10.00`
- Given a ledger with an invalid entry on line 2, when `tl summary` runs, then it prints nothing on stdout, names `line 2` on stderr and exits 1
