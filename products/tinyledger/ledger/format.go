package ledger

import "fmt"

// FormatCents prints cents as a decimal amount with two places: -350 is "-3.50".
func FormatCents(c int64) string {
	sign := ""
	if c < 0 {
		sign, c = "-", -c
	}
	return fmt.Sprintf("%s%d.%02d", sign, c/100, c%100)
}
