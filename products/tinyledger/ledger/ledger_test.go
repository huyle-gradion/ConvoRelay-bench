package ledger

import (
	"strings"
	"testing"
)

func TestLoadSkipsBlankLinesAndComments(t *testing.T) {
	t.Parallel()
	l, err := Load(strings.NewReader("; january\n\n2026-01-05 coffee -3.50 #food\n2026-01-06 pay 100.00\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(l) != 2 || l[1].Cents != 10000 {
		t.Errorf("Load = %+v, want the two entries", l)
	}
}

func TestLoadNamesTheBadLine(t *testing.T) {
	t.Parallel()
	_, err := Load(strings.NewReader("2026-01-05 coffee -3.50\nnonsense\n"))
	if err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Errorf("Load error = %v, want one naming line 2", err)
	}
}

func TestBalanceSumsEveryEntry(t *testing.T) {
	t.Parallel()
	l := Ledger{{Cents: 10000}, {Cents: -350}, {Cents: -1}}
	if got := l.Balance(); got != 9649 {
		t.Errorf("Balance = %d, want 9649", got)
	}
}
