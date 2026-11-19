// Package ledger reads a plain-text ledger and sums it.
//
// A ledger file has one entry per line:
//
//	2026-01-05 coffee beans -3.50 #food
//
// a date, a description, an amount in the currency's main unit (negative is spending) and an
// optional #tag. Blank lines and lines starting with ";" are comments.
package ledger

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Entry is one line of a ledger file. Amounts are whole cents, never floats.
type Entry struct {
	Date  string
	Desc  string
	Cents int64
	Tag   string
}

var lineRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})\s+(.+?)\s+(-?\d+(?:\.\d{1,2})?)(?:\s+#(\w+))?$`)

// Parse reads one entry line.
func Parse(line string) (Entry, error) {
	m := lineRe.FindStringSubmatch(line)
	if m == nil {
		return Entry{}, fmt.Errorf("invalid entry %q", line)
	}
	cents, err := parseCents(m[3])
	if err != nil {
		return Entry{}, err
	}
	return Entry{Date: m[1], Desc: m[2], Cents: cents, Tag: m[4]}, nil
}

// parseCents turns "-3.5" into -350.
func parseCents(s string) (int64, error) {
	negative := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	whole, frac, _ := strings.Cut(s, ".")
	for len(frac) < 2 {
		frac += "0"
	}
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid amount %q: %v", s, err)
	}
	f, err := strconv.ParseInt(frac, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid amount %q: %v", s, err)
	}
	cents := w*100 + f
	if negative {
		cents = -cents
	}
	return cents, nil
}
