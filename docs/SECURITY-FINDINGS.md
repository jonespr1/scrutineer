# Security findings

Repo-local register, appended to by security audit runs and manual review. When
fixed, set Status to Closed with the date; never delete rows.

| # | Date found | Finding | Severity | Location | Status | Fixed in |
|---|-----------|---------|----------|----------|--------|----------|

## Dependency scan: N/A

Checked by hand on 2026-11-04: this repository holds workflows, shell scripts and
benchmark fixtures, with no language dependency manifest or lockfile, so it does
not run the weekly dependency scan (stour-standards `standards/devops.md` rule 24).
Its benchmark Python scripts import only the standard library, and
`benchmark/manifest.json` is the benchmark's list of planted bugs, not a dependency
manifest.

GitHub Actions pins in its workflows are still dependencies. The scan does not read
them; Dependabot updates them (`.github/dependabot.yml`, ecosystem `github-actions`).

Add the scan caller if a manifest ever appears.
