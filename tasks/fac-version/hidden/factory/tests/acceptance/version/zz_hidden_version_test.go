package version_test

import (
	"bytes"
	"strings"
	"testing"

	"github.com/huyle-gradion/turbo-12f/internal/cli"
)

func hiddenT12(args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	code = cli.Main(args, &out, &errOut, cli.Deps{})
	return code, out.String(), errOut.String()
}

func TestHiddenVersionCommandPrintsTheVersion(t *testing.T) {
	code, out, errOut := hiddenT12("version")
	if code != 0 || out != "t12 0.3.0-dev\n" || errOut != "" {
		t.Errorf("t12 version = %d, stdout %q, stderr %q; want 0, \"t12 0.3.0-dev\\n\", \"\"", code, out, errOut)
	}
}

func TestHiddenDashDashVersionPrintsTheSameAsTheCommand(t *testing.T) {
	code, out, errOut := hiddenT12("--version")
	if code != 0 || out != "t12 0.3.0-dev\n" || errOut != "" {
		t.Errorf("t12 --version = %d, stdout %q, stderr %q; want 0, \"t12 0.3.0-dev\\n\", \"\"", code, out, errOut)
	}
}

func TestHiddenVersionWithAnArgumentIsAUsageError(t *testing.T) {
	code, out, errOut := hiddenT12("version", "extra")
	if code != 2 || out != "" || !strings.Contains(errOut, "usage: t12 version") {
		t.Errorf("t12 version extra = %d, stdout %q, stderr %q; want 2, \"\", a line with \"usage: t12 version\"", code, out, errOut)
	}
}

func TestHiddenTheUsageListsVersion(t *testing.T) {
	code, out, errOut := hiddenT12()
	var listed bool
	for _, field := range strings.FieldsFunc(errOut, func(r rune) bool { return strings.ContainsRune("{},| \n", r) }) {
		listed = listed || field == "version"
	}
	if code != 2 || out != "" || !listed {
		t.Errorf("t12 = %d, stdout %q, stderr %q; want 2, \"\", usage listing version", code, out, errOut)
	}
}
