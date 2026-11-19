package cli_test

import (
	"bytes"
	"strings"
	"testing"

	"tinyledger/internal/cli"
)

func hiddenTags(t *testing.T, input string) string {
	t.Helper()
	var out, errOut bytes.Buffer
	if code := cli.Run([]string{"tags"}, strings.NewReader(input), &out, &errOut); code != 0 {
		t.Fatalf("tags exited %d: %s", code, errOut.String())
	}
	return out.String()
}

// hiddenAlways runs tags 60 times and fails at the first output that is not want.
func hiddenAlways(t *testing.T, input, want string) {
	t.Helper()
	for i := 0; i < 60; i++ {
		if got := hiddenTags(t, input); got != want {
			t.Fatalf("run %d printed %q, want %q", i+1, got, want)
		}
	}
}

const hiddenFiveTags = "2026-01-01 one -1.00 #a\n2026-01-02 two -5.00 #b\n2026-01-03 three -5.00 #c\n2026-01-04 four 2.00 #d\n2026-01-05 five 0.50 #e\n"

func TestHiddenTagsAreSortedByTotalThenName(t *testing.T) {
	hiddenAlways(t, hiddenFiveTags, "b -5.00\nc -5.00\na -1.00\ne 0.50\nd 2.00\n")
}

func TestHiddenTagsWithEqualTotalsAreSortedByName(t *testing.T) {
	hiddenAlways(t, "2026-01-01 one -2.00 #z\n2026-01-02 two -2.00 #y\n", "y -2.00\nz -2.00\n")
}

func TestHiddenTagsDoNotDependOnFileOrder(t *testing.T) {
	lines := strings.SplitAfter(strings.TrimSuffix(hiddenFiveTags, "\n"), "\n")
	var reversed []string
	for i := len(lines) - 1; i >= 0; i-- {
		reversed = append(reversed, strings.TrimSuffix(lines[i], "\n")+"\n")
	}
	hiddenAlways(t, strings.Join(reversed, ""), "b -5.00\nc -5.00\na -1.00\ne 0.50\nd 2.00\n")
}
