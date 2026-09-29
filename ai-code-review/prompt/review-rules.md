## Shared review rules

These rules apply to every repository. The repository-specific review
direction and guidance that follow add to them; they do not replace them.

### What to review

Focus on the lines this pull request changes and their direct blast radius.
Do not review unrelated pre-existing code. Report, in priority order:

1. **Bugs** — logic errors, wrong conditions, off-by-one, null or missing-value
   handling, error handling, concurrency or async mistakes, resource leaks.
2. **Regressions** — behaviour, API or data contracts the change breaks for
   existing callers, consumers or users.
3. **Security** — injection, unsafe deserialisation or rendering, secrets
   committed to the repository, missing authorisation or input validation,
   and unsafe handling of untrusted data.
4. **Missing tests** — changed behaviour or bug fixes without matching test
   coverage, or tests that no longer exercise what they claim to.
5. **Duplicate implementations** — changed code that clearly re-implements an
   existing function, component, hook, class, utility or equivalent
   abstraction (see below).

Mention readability, maintainability and repository conventions only when
they are likely to cause a real problem. Skip pure style issues that a linter
or formatter would catch.

### How to judge

- Only report issues supported by evidence from the diff or repository code.
  Read relevant surrounding code before claiming something is broken.
- If unsure, verify by reading more code or leave the issue out. A few
  high-confidence findings are worth more than a speculative list.
- Every finding must point to a specific file and changed line in the pull
  request head.
- Review only changes in the diff and their direct consequences. The checkout
  is at the pull request head, so its files must match the right-hand side of
  the diff. Report a mismatch rather than reasoning from inconsistent context.
- It is fine to report no findings.

### Duplicate implementations

Check whether code that this pull request adds or changes re-implements a
function, component, hook, class, utility or equivalent abstraction that
already exists in the repository.

- Before accepting a newly added helper or abstraction, search `{{REPO_DIR}}`
  with grep and glob for existing code with the same purpose: similar names,
  the same inputs and outputs, or the same logic. Start from any reuse
  locations named in the repository-specific guidance.
- Report duplication only when there is clear evidence: the existing code does
  the same job, and reusing, extending or consolidating it is practical.
  Similar-looking code with different behaviour, contracts, dependencies or
  ownership is not duplication. Neither is a short idiom or a thin wrapper
  that adds meaning.
- Anchor the finding to the changed line in the diff, and cite the existing
  implementation as a link to its file and line in the finding.
- Do not report duplication that exists only in code the pull request does not
  change. This is not an audit of pre-existing code.
- Duplication is usually `🟡 Low`. Use `🟠 Medium` when the copy already
  behaves differently from the original, or duplicates non-trivial logic that
  must stay in sync with it.
