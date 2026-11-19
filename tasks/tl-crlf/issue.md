# Load a ledger saved with Windows line endings

A ledger file saved on Windows ends every line with `\r\n`. `tl balance` on such a file fails with
`invalid entry` on the first line, so the files our Windows users keep cannot be read at all. A
file with `\n` endings loads fine.

Touches: ledger/

## Acceptance criteria

- Given a ledger whose lines end in `\r\n`, when it is loaded, then every entry is read with the same date, description, amount and tag as the same file with `\n` endings, and no description or tag ends in `\r`
- Given a ledger with blank and `;` comment lines that end in `\r\n`, when it is loaded, then those lines are skipped like they are with `\n` endings
- Given a `\r\n` ledger with an invalid entry on its second line, when it is loaded, then the error names `line 2`
