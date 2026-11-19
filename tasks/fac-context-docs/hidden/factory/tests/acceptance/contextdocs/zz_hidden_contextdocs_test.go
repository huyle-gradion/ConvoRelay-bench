package contextdocs_test

import (
	"encoding/json"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/huyle-gradion/turbo-12f/internal/profile"
)

// contextDocs reads Profile.ContextDocs by name, so that a profile package without the field fails
// these tests one by one instead of failing to compile.
func contextDocs(t *testing.T, p profile.Profile) []string {
	t.Helper()
	f := reflect.ValueOf(p).FieldByName("ContextDocs")
	if !f.IsValid() {
		t.Fatal("profile.Profile has no ContextDocs field")
	}
	docs, ok := f.Interface().([]string)
	if !ok {
		t.Fatalf("Profile.ContextDocs is a %s, want []string", f.Type())
	}
	return docs
}

func TestHiddenParseKeepsContextDocsInOrder(t *testing.T) {
	p, err := profile.Parse([]byte(`{"version":3,"context_docs":["docs/b.md","docs/a.md"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := contextDocs(t, p), []string{"docs/b.md", "docs/a.md"}; !slices.Equal(got, want) {
		t.Errorf("ContextDocs = %v, want %v", got, want)
	}
}

func TestHiddenAProfileWithoutContextDocsHasNone(t *testing.T) {
	p, err := profile.Parse([]byte(`{"version":3}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := contextDocs(t, p); len(got) != 0 {
		t.Errorf("ContextDocs = %v, want none", got)
	}
}

func TestHiddenParseRefusesContextDocsThatAreNotRelativePathsInsideTheRepo(t *testing.T) {
	const want = "context_docs must be a list of relative paths"
	for _, value := range []string{`["/etc/passwd"]`, `["../outside.md"]`, `"docs/a.md"`} {
		_, err := profile.Parse([]byte(`{"version":3,"context_docs":` + value + `}`))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("Parse with context_docs %s: error %v, want one containing %q", value, err, want)
		}
	}
}

func TestHiddenATaskFileMayNotCarryContextDocs(t *testing.T) {
	p, err := profile.Parse([]byte(`{"version":3,"context_docs":["docs/a.md"]}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	var task map[string]any
	if err := json.Unmarshal([]byte(`{"id":"t-1","context_docs":["docs/a.md"]}`), &task); err != nil {
		t.Fatal(err)
	}
	_, err = profile.Apply(p, task)
	if err == nil || !strings.Contains(err.Error(), "context_docs belongs in") {
		t.Errorf("Apply error = %v, want one containing \"context_docs belongs in\"", err)
	}
}
