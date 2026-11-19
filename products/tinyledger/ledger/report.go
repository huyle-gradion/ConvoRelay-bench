package ledger

import (
	"fmt"
	"strings"
)

// TagTotals is the sum of the entries of each tag; entries without a tag are left out.
func (l Ledger) TagTotals() map[string]int64 {
	totals := map[string]int64{}
	for _, e := range l {
		if e.Tag != "" {
			totals[e.Tag] += e.Cents
		}
	}
	return totals
}

// TagReport is one "tag amount" line per tag.
func (l Ledger) TagReport() string {
	var b strings.Builder
	for tag, cents := range l.TagTotals() {
		fmt.Fprintf(&b, "%s %s\n", tag, FormatCents(cents))
	}
	return b.String()
}

// List is one line per entry: date, description, amount and tag.
func (l Ledger) List() string {
	var b strings.Builder
	for _, e := range l {
		fmt.Fprintf(&b, "%s  %s  %s", e.Date, e.Desc, FormatCents(e.Cents))
		if e.Tag != "" {
			fmt.Fprintf(&b, "  #%s", e.Tag)
		}
		b.WriteByte('\n')
	}
	return b.String()
}
