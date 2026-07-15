#!/usr/bin/env python3
"""Summarise where two Scrutineer reviewers (Gemini and GLM) diverged on a real PR.

Usage:  python3 benchmark/divergence.py <owner/repo> <pr> [<pr> ...]

For each PR it reads the Scrutineer review comments (via `gh api`), extracts each model's findings
(severity + file/line + title), and reports:
  - findings only one model raised (the complementarity that justifies running both),
  - findings both raised but at a DIFFERENT severity (calibration split),
  - per-model counts by severity.

This is a HEURISTIC first-pass on free-text reviews - matching is by file + nearby line, so treat it
as an aid for the observations log, not a precise diff. Output is markdown, ready to paste in.
No API cost (reads existing comments). Requires `gh` authenticated.
"""
import json, re, subprocess, sys

SEV_ORDER = {"Critical": 4, "High": 3, "Medium": 2, "Low": 1}
SEV_RE = re.compile(r"(?:🔴|🟠|🟡|🟢)?\s*\b(Critical|High|Medium|Low)\b", re.I)
HEADER_RE = re.compile(r"^#{2,4}\s*(?:🔴|🟠|🟡|🟢)?\s*(Critical|High|Medium|Low)\b", re.I)
FILE_RE = re.compile(r"`?([\w./-]+\.(?:tsx|ts|jsx|js|py|go|rs|java|rb|css|astro|yml|yaml|sh|json))`?", re.I)
LINE_RE = re.compile(r"(?:line|lines|:|~|L)\s*[:~]?\s*(\d{1,4})", re.I)


def gh_comments(repo, pr):
    r = subprocess.run(["gh", "api", f"repos/{repo}/issues/{pr}/comments", "--paginate"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return []


def first_review(bots, kind):
    for b in bots:
        if b.startswith("## \U0001f916 Review") and kind in b.lower():
            return b
    return None


def parse_findings(body):
    """Heuristic: walk severity sections, treat each bullet/numbered item as one finding."""
    if not body:
        return []
    findings, sev = [], None
    cur = None
    for ln in body.splitlines():
        s = ln.strip()
        indent = len(ln) - len(ln.lstrip())
        h = HEADER_RE.match(s)
        if h:
            sev = h.group(1).capitalize()
            continue
        # A non-severity level-2 section (## Summary / ## Findings / ## Positives) ends findings
        # collection - otherwise the last severity leaks onto the Positives bullets.
        if re.match(r"^##\s", s):
            sev = None
            if cur:
                findings.append(cur); cur = None
            continue
        # Only a TOP-LEVEL bullet or an #### header starts a new finding; indented items (numbered
        # fix sub-steps, nested bullets) are continuation of the current finding.
        is_bullet = bool(re.match(r"^([-*]\s|#{4}\s)", s)) and indent <= 1
        if is_bullet and sev:
            if cur:
                findings.append(cur)
            title = re.sub(r"^([-*]\s|#{4}\s|\d+\.\s)", "", s)
            title = re.sub(r"\*\*|`", "", title).strip()
            cur = {"severity": sev, "text": title, "title": title[:90]}
        elif cur is not None:
            cur["text"] += " " + s
    if cur:
        findings.append(cur)
    # Attach file/line from each finding's accumulated text.
    for f in findings:
        fm = FILE_RE.search(f["text"]); lm = LINE_RE.search(f["text"])
        f["file"] = fm.group(1).split("/")[-1] if fm else None
        f["line"] = int(lm.group(1)) if lm else None
        f.pop("text", None)
    return findings


_STOP = {"line", "lines", "file", "page", "search", "code", "when", "then", "only", "does",
         "isn", "its", "each", "every", "before", "after", "which", "would", "could", "should",
         "will", "still", "with", "that", "this", "from", "into", "onto", "null", "your", "user"}


def _toks(s):
    """Meaningful lowercase word tokens (>=4 chars, minus common filler)."""
    return {w for w in re.findall(r"[a-z][a-z0-9]{3,}", (s or "").lower()) if w not in _STOP}


def matched(a, b):
    """Same finding? Requires the same file, then EITHER lines within 15 AND >=1 shared title
    keyword, OR (when a line is missing on one side) >=2 shared title keywords. The keyword guard
    stops two distinct findings that merely sit near each other in a dense file from merging, while
    the wider window lets the same finding match when the two models cite slightly different lines."""
    if not (a["file"] and b["file"] and a["file"] == b["file"]):
        return False
    shared = len(_toks(a["title"]) & _toks(b["title"]))
    if a["line"] is not None and b["line"] is not None:
        return abs(a["line"] - b["line"]) <= 15 and shared >= 1
    return shared >= 2


def report_pr(repo, pr):
    cs = gh_comments(repo, pr)
    bots = [c["body"] for c in cs if c.get("user", {}).get("login") == "github-actions[bot]"]
    g = parse_findings(first_review(bots, "gemini"))
    z = parse_findings(first_review(bots, "glm"))
    g_used, z_used = set(), set()
    shared, splits = [], []
    for i, a in enumerate(g):
        for j, b in enumerate(z):
            if j in z_used:
                continue
            if matched(a, b):
                g_used.add(i); z_used.add(j)
                if a["severity"] != b["severity"]:
                    splits.append((a, b))
                else:
                    shared.append((a, b))
                break
    g_only = [a for i, a in enumerate(g) if i not in g_used]
    z_only = [b for j, b in enumerate(z) if j not in z_used]

    def line(f):
        loc = f["file"] or "?"
        if f["line"]:
            loc += f":{f['line']}"
        return f"  - [{f['severity']}] `{loc}` - {f['title']}"

    out = [f"### {repo} #{pr}", ""]
    if not bots or (not g and not z):
        out.append("_No parseable Gemini/GLM reviews found._"); out.append(""); return "\n".join(out)
    out.append(f"**Gemini-only ({len(g_only)}):**")
    out += [line(f) for f in g_only] or ["  - (none)"]
    out.append(f"\n**GLM-only ({len(z_only)}):**")
    out += [line(f) for f in z_only] or ["  - (none)"]
    if splits:
        out.append(f"\n**Severity splits (same locus, different severity) ({len(splits)}):**")
        for a, b in splits:
            out.append(f"  - `{a['file'] or '?'}` - Gemini **{a['severity']}** vs GLM **{b['severity']}**: {a['title']}")
    out.append(f"\n**Agreed ({len(shared)}):** " + (", ".join(f"{a['severity']} `{a['file'] or '?'}`" for a, b in shared) or "(none)"))
    gc = {s: sum(1 for f in g if f["severity"] == s) for s in SEV_ORDER}
    zc = {s: sum(1 for f in z if f["severity"] == s) for s in SEV_ORDER}
    out.append(f"\n_Counts - Gemini: {gc} · GLM: {zc}_")
    out.append("")
    return "\n".join(out)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: divergence.py <owner/repo> <pr> [<pr> ...]")
    repo = sys.argv[1]
    print(f"# Gemini vs GLM divergence - {repo}\n")
    for pr in sys.argv[2:]:
        print(report_pr(repo, pr))


if __name__ == "__main__":
    main()
