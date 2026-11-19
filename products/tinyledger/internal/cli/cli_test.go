package cli

import (
	"bytes"
	"strings"
	"testing"
)

const sample = "2026-01-05 coffee -3.50 #food\n2026-01-06 pay 100.00\n"

func run(t *testing.T, input string, args ...string) (code int, out, errOut string) {
	t.Helper()
	var o, e bytes.Buffer
	code = Run(args, strings.NewReader(input), &o, &e)
	return code, o.String(), e.String()
}

func TestBalancePrintsTheSumOfStdin(t *testing.T) {
	t.Parallel()
	if code, out, _ := run(t, sample, "balance"); code != 0 || out != "96.50\n" {
		t.Errorf("balance = %d %q, want 0 \"96.50\\n\"", code, out)
	}
}

func TestListPrintsTheEntries(t *testing.T) {
	t.Parallel()
	code, out, _ := run(t, sample, "list")
	if code != 0 || out != "2026-01-05  coffee  -3.50  #food\n2026-01-06  pay  100.00\n" {
		t.Errorf("list = %d %q", code, out)
	}
}

func TestAnUnreadableLedgerExitsOneWithTheLine(t *testing.T) {
	t.Parallel()
	code, out, errOut := run(t, "nonsense\n", "balance")
	if code != 1 || out != "" || !strings.Contains(errOut, "line 1") {
		t.Errorf("= %d %q %q, want exit 1, no output, a message naming line 1", code, out, errOut)
	}
}

func TestAnUnknownCommandPrintsUsageAndExitsTwo(t *testing.T) {
	t.Parallel()
	if code, _, errOut := run(t, "", "frobnicate"); code != 2 || !strings.Contains(errOut, "usage: tl") {
		t.Errorf("= %d %q, want exit 2 and the usage", code, errOut)
	}
}
