package cli_test

import (
	"bytes"
	"strings"
	"testing"

	"tinyledger/internal/cli"
)

const hiddenTagLedger = "2026-01-05 coffee -3.50 #food\n2026-01-06 lunch -9.00 #food\n2026-01-07 present 5.00 #gift\n2026-01-08 pay 7.00\n"

func hiddenRun(t *testing.T, input string, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := cli.Run(args, strings.NewReader(input), &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestHiddenBalanceTagSumsOnlyThatTag(t *testing.T) {
	code, out, errOut := hiddenRun(t, hiddenTagLedger, "balance", "--tag", "food")
	if code != 0 || out != "-12.50\n" {
		t.Errorf("balance --tag food = %d %q (stderr %q), want 0 \"-12.50\\n\"", code, out, errOut)
	}
}

func TestHiddenBalanceOfAnUnknownTagIsZero(t *testing.T) {
	code, out, errOut := hiddenRun(t, hiddenTagLedger, "balance", "--tag", "nothing")
	if code != 0 || out != "0.00\n" {
		t.Errorf("balance --tag nothing = %d %q (stderr %q), want 0 \"0.00\\n\"", code, out, errOut)
	}
}

func TestHiddenListTagPrintsOnlyThatTagInFileOrder(t *testing.T) {
	code, out, errOut := hiddenRun(t, hiddenTagLedger, "list", "--tag", "food")
	want := "2026-01-05  coffee  -3.50  #food\n2026-01-06  lunch  -9.00  #food\n"
	if code != 0 || out != want {
		t.Errorf("list --tag food = %d %q (stderr %q), want 0 %q", code, out, errOut, want)
	}
}

func TestHiddenTagsAreCaseSensitive(t *testing.T) {
	code, out, errOut := hiddenRun(t, hiddenTagLedger, "balance", "--tag", "Food")
	if code != 0 || out != "0.00\n" {
		t.Errorf("balance --tag Food = %d %q (stderr %q), want 0 \"0.00\\n\"", code, out, errOut)
	}
}
