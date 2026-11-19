---
name: verify
description: "Drive the bench's toy product (a Go module with greet.go): call Greet and read what it returns. Use when verifying the dry-run product."
---

# Verify the toy

Surface: a Go library. Launch: nothing to start (`go build ./...` proves it compiles). Drive: `go run` a throwaway `main` that calls `Greet` and prints the result. Evidence: the printed line. Cleanup: delete the throwaway file.
