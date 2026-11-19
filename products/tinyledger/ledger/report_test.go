package ledger

import "testing"

func TestTagTotalsSumPerTagAndLeaveOutUntagged(t *testing.T) {
	t.Parallel()
	l := Ledger{{Cents: -350, Tag: "food"}, {Cents: -900, Tag: "food"}, {Cents: 500, Tag: "gift"}, {Cents: 7}}
	got := l.TagTotals()
	if len(got) != 2 || got["food"] != -1250 || got["gift"] != 500 {
		t.Errorf("TagTotals = %v, want food -1250 and gift 500", got)
	}
}

func TestListPrintsOneLinePerEntry(t *testing.T) {
	t.Parallel()
	l := Ledger{{Date: "2026-01-05", Desc: "coffee", Cents: -350, Tag: "food"}, {Date: "2026-01-06", Desc: "pay", Cents: 10000}}
	want := "2026-01-05  coffee  -3.50  #food\n2026-01-06  pay  100.00\n"
	if got := l.List(); got != want {
		t.Errorf("List = %q, want %q", got, want)
	}
}

func TestTagReportWithOneTag(t *testing.T) {
	t.Parallel()
	if got := (Ledger{{Cents: -350, Tag: "food"}}).TagReport(); got != "food -3.50\n" {
		t.Errorf("TagReport = %q", got)
	}
}
