package ledger_test

import (
	"strings"
	"testing"

	"tinyledger/ledger"
)

func TestHiddenParseRefusesADateThatDoesNotExist(t *testing.T) {
	for _, date := range []string{"2026-02-30", "2026-04-31", "2026-13-01", "2026-00-10"} {
		_, err := ledger.Parse(date + " rent -500.00")
		if err == nil {
			t.Errorf("Parse with date %s succeeded, want an error", date)
		} else if !strings.Contains(err.Error(), "date") {
			t.Errorf("Parse with date %s: error %q does not mention the date", date, err)
		}
	}
}

func TestHiddenParseKnowsLeapDays(t *testing.T) {
	for _, date := range []string{"2024-02-29", "2026-12-31", "2026-02-28"} {
		if _, err := ledger.Parse(date + " rent -500.00"); err != nil {
			t.Errorf("Parse with date %s: %v", date, err)
		}
	}
	if _, err := ledger.Parse("2026-02-29 rent -500.00"); err == nil {
		t.Error("Parse with date 2026-02-29 succeeded, want an error: 2026 is not a leap year")
	}
}

func TestHiddenLoadNamesTheLineOfABadDate(t *testing.T) {
	_, err := ledger.Load(strings.NewReader("2026-01-05 coffee -3.50\n2026-02-30 rent -500.00\n"))
	if err == nil || !strings.Contains(err.Error(), "line 2") || !strings.Contains(err.Error(), "date") {
		t.Errorf("Load error = %v, want one naming line 2 and the date", err)
	}
}
