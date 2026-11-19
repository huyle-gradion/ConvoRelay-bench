package cli_test

import (
	"bytes"
	"strings"
	"testing"

	"tinyledger/internal/cli"
)

func hiddenSummary(t *testing.T, input string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := cli.Run([]string{"summary"}, strings.NewReader(input), &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestHiddenSummaryPrintsEntriesIncomeSpentAndBalance(t *testing.T) {
	code, out, errOut := hiddenSummary(t, "2026-01-01 pay 100.00\n2026-01-02 coffee -3.50 #food\n2026-01-03 bun -1.25\n")
	want := "entries 3\nincome 100.00\nspent 4.75\nbalance 95.25\n"
	if code != 0 || out != want {
		t.Errorf("summary = %d %q (stderr %q), want 0 %q", code, out, errOut, want)
	}
}

func TestHiddenSummaryOfAnEmptyLedgerIsAllZero(t *testing.T) {
	code, out, errOut := hiddenSummary(t, "")
	want := "entries 0\nincome 0.00\nspent 0.00\nbalance 0.00\n"
	if code != 0 || out != want {
		t.Errorf("summary = %d %q (stderr %q), want 0 %q", code, out, errOut, want)
	}
}

func TestHiddenSummaryCountsAZeroEntryButAddsNothing(t *testing.T) {
	code, out, errOut := hiddenSummary(t, "2026-01-01 nothing 0.00\n2026-01-02 pay 10.00\n")
	want := "entries 2\nincome 10.00\nspent 0.00\nbalance 10.00\n"
	if code != 0 || out != want {
		t.Errorf("summary = %d %q (stderr %q), want 0 %q", code, out, errOut, want)
	}
}

func TestHiddenSummaryOfABadLedgerExitsOneAndNamesTheLine(t *testing.T) {
	code, out, errOut := hiddenSummary(t, "2026-01-01 pay 10.00\nnonsense\n")
	if code != 1 || out != "" || !strings.Contains(errOut, "line 2") {
		t.Errorf("summary = %d %q (stderr %q), want 1, no output, a message naming line 2", code, out, errOut)
	}
}
