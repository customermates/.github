# Contributing

Create changes on a short-lived branch from the latest `main` and open a pull request back into `main`. Direct changes to `main` are not accepted.

Branch names use `<category>/<lowercase-kebab-case-description>`. Allowed categories are `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`, and `sandbox`. For example: `feat/contact-import`, `fix/oauth-callback`, or `sandbox/rewe`.

Every commit and pull request title uses Conventional Commit form:

```text
type: concise summary
type(scope): concise summary
type(scope)!: breaking summary
```

Use one of the commit types listed above except `sandbox`, which is branch-only. Keep the header at or below 100 characters, start the summary with a lowercase letter or number, and omit a trailing period. Rebase an unpublished topic branch. When synchronizing a shared topic branch without rewriting its history, merge `main` with the commit subject `chore: synchronize with main`.

Pull request descriptions must retain the required template sections, explain how the change was validated, and identify its impact and rollback. Pull requests authored by someone outside the Code Owners require Code Owner approval. Code Owner-authored pull requests still require the same policy and CI checks before they can be squash-merged into `main`.
