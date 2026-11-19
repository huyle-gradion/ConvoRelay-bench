package toy_test

import (
	"testing"

	"toy"
)

func TestHiddenGreetUsesTheName(t *testing.T) {
	if got := toy.Greet("Ana"); got != "Hello, Ana!" {
		t.Errorf("Greet(Ana) = %q, want %q", got, "Hello, Ana!")
	}
}
