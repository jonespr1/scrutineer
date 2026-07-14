#!/usr/bin/env python3
"""Score a benchmark run against the ground-truth manifest.

Usage:  python3 benchmark/score.py <run_id> [--strict]

Reads benchmark/results/<run_id>/raw/*.json (produced by run.sh), scores each model's review
of each fixture against benchmark/manifest.json, and writes:
  - benchmark/results/<run_id>/scorecard.json   (full per-bug detail)
  - benchmark/results/<run_id>/RESULTS.md        (this run's leaderboard)
  - benchmark/RESULTS.md                         (rolled-up index of all runs)

Detection heuristic (transparent on purpose): a planted bug is DETECTED when the review matches
>=1 of the bug's regex `patterns` (case-insensitive) AND either cites a line within +/- window of
the bug's anchor OR names the fixture file. `--strict` requires the line match. Raw output is kept
so a human can adjudicate any call. This is a heuristic, not an oracle — treat scores as a strong
signal, not gospel.
"""
import json
import os
import re
import sys
import glob

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = json.load(open(os.path.join(HERE, "manifest.json")))

# Severity weights for the composite detection score.
WEIGHT = {"Critical": 3.0, "High": 2.0, "Medium": 1.5, "Low": 1.0}

# --- Cost estimation for providers that don't return a USD cost (direct Gemini) ---------------
# EDITABLE ESTIMATES, USD per 1M tokens (input, output). OpenRouter costs are REAL (from the API);
# only these direct-Gemini figures are estimates — update them to your billed rates. Set to None
# to show tokens only.
PRICES = {
    "gemini-pro-latest":   (1.25, 10.0),   # estimate — confirm against your Google bill
    "gemini-flash-latest": (0.30, 2.50),   # estimate — confirm against your Google bill
}


def cited_lines(text):
    """All integers that look like line references in the review text."""
    nums = set()
    for m in re.finditer(r"(?:line[s]?\s*[:~]?\s*|:)(\d{1,4})", text, re.I):
        nums.add(int(m.group(1)))
    for m in re.finditer(r"\b(\d{1,4})\b", text):     # fall back to bare numbers too
        n = int(m.group(1))
        if 1 <= n <= 9999:
            nums.add(n)
    return nums


def detect(bug, text, filename, strict):
    window = bug.get("window", MANIFEST["scoring"]["line_window"])
    pat = any(re.search(p, text, re.I) for p in bug["patterns"])
    if not pat:
        return False
    lines = cited_lines(text)
    line_hit = any(bug["line"] - window <= n <= bug["line"] + window for n in lines)
    stem = os.path.splitext(filename)[0]
    file_hit = filename in text or stem in text
    return line_hit if strict else (line_hit or file_hit)


SEV_EMOJI = ["🔴", "🟠", "🟡"]  # Critical / High / Medium — Low excluded from FP count


def false_positives(text):
    """Count concrete Critical/High/Medium findings in a review of the CLEAN fixture."""
    if re.search(r"no (findings|issues|concerns)|looks good|nothing to flag|no bugs", text, re.I):
        # still count explicit severity markers if present, else 0
        pass
    emoji = sum(text.count(e) for e in SEV_EMOJI)
    if emoji:
        return emoji
    # No emoji: count bulleted findings that name a blocking severity.
    return len(re.findall(r"^\s*[-*].*\b(Critical|High|Medium)\b", text, re.I | re.M))


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: score.py <run_id> [--strict]")
    run_id = sys.argv[1]
    strict = "--strict" in sys.argv[2:]
    run_dir = os.path.join(HERE, "results", run_id)
    raw_dir = os.path.join(run_dir, "raw")
    if not os.path.isdir(raw_dir):
        sys.exit(f"no raw output at {raw_dir} — run run.sh first")

    bugs = MANIFEST["bugs"]
    clean_fixtures = {f["file"] for f in MANIFEST["fixtures"] if f.get("clean")}
    total_weight = sum(WEIGHT[b["severity"]] for b in bugs)
    n_crit = sum(1 for b in bugs if b["severity"] == "Critical")

    per_model = {}
    for path in sorted(glob.glob(os.path.join(raw_dir, "*.json"))):
        r = json.load(open(path))
        mid = r["model"]
        m = per_model.setdefault(mid, {
            "model": mid, "spec": r.get("spec", ""), "detected": [], "missed": [],
            "found_weight": 0.0, "missed_crit": 0, "false_positives": 0,
            "cost": 0.0, "cost_estimated": False, "latency_ms": [], "errors": [],
            "prompt_tokens": 0, "completion_tokens": 0,
        })
        text = r.get("text") or ""
        if r.get("error"):
            m["errors"].append(f"{r['fixture']}: {r['error']}")
        m["latency_ms"].append(r.get("latency_ms", 0))
        pt, ct = r.get("prompt_tokens", 0), r.get("completion_tokens", 0)
        m["prompt_tokens"] += pt
        m["completion_tokens"] += ct

        # Cost: real from OpenRouter, else estimate from the price map.
        if r.get("total_cost") is not None:
            m["cost"] += float(r["total_cost"])
        else:
            spec = r.get("spec", "")
            model_name = spec.split(":", 1)[1] if spec.startswith("gemini:") else spec
            price = PRICES.get(model_name)
            if price:
                m["cost"] += pt / 1e6 * price[0] + ct / 1e6 * price[1]
                m["cost_estimated"] = True

        if r["fixture"] in clean_fixtures:
            m["false_positives"] += false_positives(text)
            continue

        for b in [b for b in bugs if b["fixture"] == r["fixture"]]:
            if detect(b, text, r["fixture"], strict):
                m["detected"].append(b["id"])
                m["found_weight"] += WEIGHT[b["severity"]]
            else:
                m["missed"].append(b["id"])
                if b["severity"] == "Critical":
                    m["missed_crit"] += 1

    # Assemble ranked table.
    rows = []
    for m in per_model.values():
        det = len(m["detected"])
        rows.append({
            **m,
            "detection_pct": round(100 * m["found_weight"] / total_weight, 1),
            "detected_count": det,
            "avg_latency_ms": int(sum(m["latency_ms"]) / len(m["latency_ms"])) if m["latency_ms"] else 0,
        })
    rows.sort(key=lambda x: (-x["detection_pct"], x["cost"] or 9e9))

    scorecard = {
        "run_id": run_id, "strict": strict, "total_bugs": len(bugs),
        "total_weight": total_weight, "n_critical": n_crit, "models": rows,
    }
    json.dump(scorecard, open(os.path.join(run_dir, "scorecard.json"), "w"), indent=2)

    # Per-run RESULTS.md
    lines = [f"# Benchmark run `{run_id}`", ""]
    meta_path = os.path.join(run_dir, "meta.json")
    if os.path.exists(meta_path):
        meta = json.load(open(meta_path))
        rt = meta.get("routing", {})
        lines.append(f"Routing: hosts=`{rt.get('openrouter_hosts') or 'any'}` "
                     f"sort=`{rt.get('sort')}` zdr=`{rt.get('zdr')}`  ·  "
                     f"slugs validated: {meta.get('slugs_validated')}")
        lines.append("")
    lines += [
        f"Scored against {len(bugs)} planted bugs ({n_crit} Critical) across "
        f"{len(MANIFEST['fixtures'])-len(clean_fixtures)} buggy fixtures + "
        f"{len(clean_fixtures)} clean control. Detection is severity-weighted. "
        f"{'STRICT (line match required).' if strict else ''}",
        "",
        "| Rank | Model | Detection | Bugs found | Missed Crit | False+ (clean) | Avg latency | Cost / run | Notes |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for i, r in enumerate(rows, 1):
        cost = "n/a" if (r["cost"] == 0 and not r["cost_estimated"]) else \
               f"{'~' if r['cost_estimated'] else ''}${r['cost']:.4f}"
        note = ""
        if r["errors"]:
            note = f"⚠️ {len(r['errors'])} call error(s)"
        lines.append(
            f"| {i} | {r['model']} | {r['detection_pct']}% | "
            f"{r['detected_count']}/{len(bugs)} | {r['missed_crit']} | {r['false_positives']} | "
            f"{r['avg_latency_ms']} ms | {cost} | {note} |")
    lines += ["", "`~` = estimated cost (direct Gemini token estimate); un-prefixed = real OpenRouter USD.",
              "", "See `scorecard.json` for the per-bug detection matrix and `raw/` for full model output."]
    open(os.path.join(run_dir, "RESULTS.md"), "w").write("\n".join(lines) + "\n")

    # Rolled-up index
    runs = sorted(d for d in os.listdir(os.path.join(HERE, "results"))
                  if os.path.isdir(os.path.join(HERE, "results", d)))
    idx = ["# Scrutineer benchmark — results index", "",
           "Standardised model comparison for Scrutineer. Each run scores every configured model",
           "against the planted-bug fixtures in `benchmark/fixtures/` (ground truth in `manifest.json`).",
           "Newest run first.", ""]
    for rid in reversed(runs):
        sc_path = os.path.join(HERE, "results", rid, "scorecard.json")
        if not os.path.exists(sc_path):
            continue
        sc = json.load(open(sc_path))
        top = sc["models"][0] if sc["models"] else None
        best = f"best: **{top['model']}** ({top['detection_pct']}%)" if top else "no models"
        idx.append(f"- [`{rid}`](results/{rid}/RESULTS.md) — {len(sc['models'])} models, {best}")
    open(os.path.join(HERE, "RESULTS.md"), "w").write("\n".join(idx) + "\n")

    print(f"Scored {len(rows)} models -> {os.path.join(run_dir, 'RESULTS.md')}")
    for r in rows:
        print(f"  {r['detection_pct']:5.1f}%  {r['detected_count']}/{len(bugs)}  "
              f"FP={r['false_positives']}  {r['model']}")


if __name__ == "__main__":
    main()
