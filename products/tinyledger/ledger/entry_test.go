package ledger

import "testing"

func TestParseReadsDateDescriptionAmountAndTag(t *testing.T) {
	t.Parallel()
	got, err := Parse("2026-01-05 coffee beans -3.50 #food")
	if err != nil {
		t.Fatal(err)
	}
	want := Entry{Date: "2026-01-05", Desc: "coffee beans", Cents: -350, Tag: "food"}
	if got != want {
		t.Errorf("Parse = %+v, want %+v", got, want)
	}
}

func TestParseTakesWholeAmountsAndOneDecimal(t *testing.T) {
	t.Parallel()
	for line, want := range map[string]int64{"2026-01-05 pay 100": 10000, "2026-01-05 tip 2.5": 250, "2026-01-05 fee -0.05": -5} {
		got, err := Parse(line)
		if err != nil || got.Cents != want {
			t.Errorf("Parse(%q) = %d, %v; want %d", line, got.Cents, err, want)
		}
	}
}

func TestParseRefusesALineThatIsNotAnEntry(t *testing.T) {
	t.Parallel()
	for _, line := range []string{"", "coffee -3.50", "2026-01-05 coffee", "2026-01-05 coffee three"} {
		if _, err := Parse(line); err == nil {
			t.Errorf("Parse(%q) succeeded, want an error", line)
		}
	}
}
