# Security findings

Repo-local register, appended to by security audit runs and manual review. When
fixed, set Status to Closed with the date; never delete rows.

| # | Date found | Finding | Severity | Location | Status | Fixed in |
|---|-----------|---------|----------|----------|--------|----------|

## Dependency scan: N/A

Checked by hand on 2026-11-04: this repository has no dependency manifest or
lockfile in any language, so it does not run the weekly dependency scan
(stour-standards `standards/devops.md` rule 24). Workflows, shell scripts and benchmark fixtures. Its Python and JavaScript files are scripts and fixtures with no manifest or lockfile beside them.

Add the scan caller if a manifest ever appears.
