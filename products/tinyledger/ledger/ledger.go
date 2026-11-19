package ledger

import (
	"fmt"
	"io"
	"strings"
)

// Ledger is the entries of one file, in file order.
type Ledger []Entry

// Load reads a ledger. A line that is not an entry fails the load with its line number.
func Load(r io.Reader) (Ledger, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	var l Ledger
	for i, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		e, err := Parse(line)
		if err != nil {
			return nil, fmt.Errorf("line %d: %v", i+1, err)
		}
		l = append(l, e)
	}
	return l, nil
}

// Balance is the sum of every entry, in cents.
func (l Ledger) Balance() int64 {
	var total int64
	for _, e := range l {
		total += e.Cents
	}
	return total
}
