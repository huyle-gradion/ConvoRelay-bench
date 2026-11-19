package ledger

import "testing"

func TestFormatCentsPrintsTwoPlacesAndTheSign(t *testing.T) {
	t.Parallel()
	for cents, want := range map[int64]string{0: "0.00", 5: "0.05", 350: "3.50", -350: "-3.50", -50: "-0.50", 123456: "1234.56"} {
		if got := FormatCents(cents); got != want {
			t.Errorf("FormatCents(%d) = %q, want %q", cents, got, want)
		}
	}
}
