// Package cli is the tl command line: it reads a ledger from a file or stdin and prints a view of it.
package cli

import (
	"flag"
	"fmt"
	"io"
	"os"

	"tinyledger/ledger"
)

const usage = "usage: tl balance|list|tags [--file PATH]"

// Run runs one tl command and returns its exit code: 0 ok, 1 the ledger could not be read, 2 usage.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	set := flag.NewFlagSet("tl "+args[0], flag.ContinueOnError)
	set.SetOutput(stderr)
	file := set.String("file", "", "ledger file; stdin when empty")
	switch args[0] {
	case "balance", "list", "tags":
	default:
		fmt.Fprintln(stderr, usage)
		return 2
	}
	if err := set.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	if set.NArg() > 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	in := stdin
	if *file != "" {
		f, err := os.Open(*file)
		if err != nil {
			fmt.Fprintf(stderr, "tl: %v\n", err)
			return 1
		}
		defer f.Close()
		in = f
	}
	l, err := ledger.Load(in)
	if err != nil {
		fmt.Fprintf(stderr, "tl: %v\n", err)
		return 1
	}
	switch args[0] {
	case "balance":
		fmt.Fprintln(stdout, ledger.FormatCents(l.Balance()))
	case "list":
		fmt.Fprint(stdout, l.List())
	case "tags":
		fmt.Fprint(stdout, l.TagReport())
	}
	return 0
}
