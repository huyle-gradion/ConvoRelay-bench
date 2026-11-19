# Accept `context_docs` in the project profile

`docs/generic-factory.md` promises a profile key `context_docs`: paths a worker must read, listed in its
context and not inlined. The key is marked "Not built yet", and a profile that names it is refused as an
unknown key. This task builds the profile half: reading and checking the key. Listing the paths in
`t12 context` is a separate task and out of scope here.

Touches: factory/internal/profile/profile.go, factory/internal/profile/apply.go, factory/docs/generic-factory.md

## Decisions

- The key is profile only, like `protected_paths`: a task file that carries it is refused by the existing profile-only rule.
- The parsed list is the exported field `ContextDocs []string` of `profile.Profile`, kept in the order written.
- The error text for a bad value follows the other path lists: `context_docs must be a list of relative paths`.

## Acceptance criteria

- Given a profile of version 3 with `"context_docs": ["docs/b.md", "docs/a.md"]`, when it is parsed, then `ContextDocs` is `docs/b.md`, `docs/a.md` in that order
- Given a profile without `context_docs`, when it is parsed, then `ContextDocs` is empty
- Given `"context_docs": ["/etc/passwd"]`, when the profile is parsed, then parsing fails with an error that contains `context_docs must be a list of relative paths`
- Given `"context_docs": ["../outside.md"]`, when the profile is parsed, then parsing fails with the same message
- Given `"context_docs": "docs/a.md"` (a string, not a list), when the profile is parsed, then parsing fails with the same message
- Given a task file with a `context_docs` key, when the profile is applied to it, then it is refused with an error that contains `context_docs belongs in`
