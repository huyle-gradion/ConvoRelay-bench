# Make `tl tags` print in a fixed order

`tl tags` prints the per-tag totals in a different order on every run, so its output cannot be diffed,
tested or pasted into a report twice. Print the tags sorted by total, the biggest spending first
(smallest total first), and by tag name when two totals are equal.

Touches: ledger/

## Decisions

- The line format (`TAG AMOUNT`) and the entries without a tag (left out) stay as they are.

## Acceptance criteria

- Given the tags a (-1.00), b (-5.00), c (-5.00), d (2.00) and e (0.50) in that order in the file, when `tl tags` runs, then it prints b, c, a, e, d, one `TAG AMOUNT` line each, and prints the same bytes on every run
- Given the tags z and y, both totalling -2.00, and z first in the file, when `tl tags` runs, then y is printed before z on every run
- Given the same entries in the reverse order in the file, when `tl tags` runs, then the output is the same as for the original order
