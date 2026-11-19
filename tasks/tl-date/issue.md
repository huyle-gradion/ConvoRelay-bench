# Refuse entries whose date does not exist

`tl` checks that a date looks like `YYYY-MM-DD` but not that the day exists, so `2026-02-30` loads and
sorts into the books as a real day. Reports built on these dates are wrong without any warning.

Touches: ledger/

## Acceptance criteria

- Given an entry line dated `2026-02-30`, `2026-04-31`, `2026-13-01` or `2026-00-10`, when it is parsed, then parsing fails and the error contains the word `date`
- Given an entry line dated `2024-02-29` (a leap day) or `2026-12-31`, when it is parsed, then it is accepted, and given `2026-02-29` it fails
- Given a ledger whose second line has the date `2026-02-30`, when it is loaded, then the error names `line 2` and contains the word `date`
