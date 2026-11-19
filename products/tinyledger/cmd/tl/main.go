// Command tl prints views of a plain-text ledger.
package main

import (
	"os"

	"tinyledger/internal/cli"
)

func main() { os.Exit(cli.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }
