package ledger_test

import (
	"strings"
	"testing"

	"tinyledger/ledger"
)

func TestHiddenLoadReadsACRLFFileLikeAnLFFile(t *testing.T) {
	lf := "2026-01-05 coffee beans -3.50 #food\n2026-01-06 pay 100.00\n"
	want, err := ledger.Load(strings.NewReader(lf))
	if err != nil {
		t.Fatal(err)
	}
	got, err := ledger.Load(strings.NewReader(strings.ReplaceAll(lf, "\n", "\r\n")))
	if err != nil {
		t.Fatalf("Load of a CRLF file: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("Load = %d entries, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("entry %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestHiddenLoadSkipsBlankAndCommentLinesOfACRLFFile(t *testing.T) {
	got, err := ledger.Load(strings.NewReader("; january\r\n\r\n2026-01-05 coffee -3.50\r\n\r\n"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got) != 1 || got[0].Desc != "coffee" {
		t.Errorf("Load = %+v, want the one coffee entry", got)
	}
}

func TestHiddenLoadNamesTheBadLineOfACRLFFile(t *testing.T) {
	_, err := ledger.Load(strings.NewReader("2026-01-05 coffee -3.50\r\nnonsense\r\n"))
	if err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Errorf("Load error = %v, want one naming line 2", err)
	}
}
