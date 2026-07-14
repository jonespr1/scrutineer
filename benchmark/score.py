#!/usr/bin/env python3
"""Score a benchmark run against the ground-truth manifest.

Usage:  python3 benchmark/score.py <run_id> [--strict]

Reads benchmark/results/<run_id>/raw/*.json (produced by run.sh), scores each model's review
of each fixture against benchmark/manifest.json, and writes:
  - benchmark/results/<run_id>/scorecard.json   (full per-bug detail + model/combination tables)
  - benchmark/results/<run_id>/RESULTS.md        (this run's leaderboard + best-value combinations)
  - benchmark/RESULTS.md                         (rolled-up index of all runs)

Detection heuristic (transparent on purpose): a planted bug is DETECTED in a trial when the review
matches >=1 of the bug's regex `patterns` (case-insensitive) AND either cites a line within +/-
window of the bug's anchor OR names the fixture file. `--strict` requires the line match. With
multiple trials per model x fixture, detection becomes a RATE across trials (temperature is 0, so a
rate below 1.0 flags a genuinely borderline finding). Raw output is kept so a human can adjudicate.
This is a heuristic, not an oracle - treat scores as a strong signal, not gospel.
"""
import json
import os
import re
import sys
import glob
import itertools
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "manifest.json"), encoding="utf-8") as _mf:
    MANIFEST = json.load(_mf)

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
    """Integers explicitly cited as line references — never stray numbers.

    Recognised forms: "line 7", "lines 7-9", "line: 7", "line ~7", and "path.ext:7" (a colon
    preceded by a filename character). Deliberately NOT treated as citations: a bare "7", a
    markdown enumerator "(1)"/"(7)", or an issue ref "#7" — each of these was inflating hits.
    In non-strict scoring the filename match still backstops detection; this keeps --strict honest.
    """
    nums = set()
    # "line 7" / "lines 7" / "line: 7" / "line ~7", including a range "lines 7-9".
    for m in re.finditer(r"lines?\s*[:~]?\s*(\d{1,4})(?:\s*[-–—]\s*(\d{1,4}))?", text, re.I):
        nums.add(int(m.group(1)))
        if m.group(2):
            nums.add(int(m.group(2)))
    # "path.py:7" / "users.ts:12" — the colon must follow a filename character (letter, _, ), ],
    # or a closing backtick/quote as in `users.ts`:12 / "users.ts":12), so "ratio 3:2" and "12:30"
    # (digit before the colon) still do not match.
    for m in re.finditer(r"""[A-Za-z_)\]`'"]:(\d{1,4})\b""", text):
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
    r"""Count concrete Critical/High/Medium findings in a review of the CLEAN control fixture.

    Judged per line. A line is a finding when — after any run of leading markdown *decoration* —
    it starts with a blocking-severity emoji (🔴/🟠/🟡) or a severity label followed by a delimiter.
    "Decoration" is the general class `PRE` below: bullets, blockquote `>`, bold `*`, brackets, and
    backticks/quotes. Generalising the prefix (rather than special-casing each wrapper) means
    "- **🔴 Critical:**", "> 🟠 High:", "- [🔴 Critical] …", "- [High] - …" and "**Critical:**"
    all count, without another regex tweak per format.

    Markdown headings are excluded because `#` is deliberately NOT decoration, so "## 🔴 Critical
    Findings" (a section title, not a finding) doesn't match.

    We deliberately do NOT add a negation check. Natural clearances — "No findings", "None found",
    "🟢 No issues" (🟢 isn't a blocking severity) — don't begin with a blocking-severity token, so
    this test already excludes them. A prefix-stripping negation check would instead wrongly drop
    real findings whose description leads with a negation ("🔴 Critical: no bounds check",
    "not validated"), so the "not" inside a finding's description is correctly still counted.

    Consequences (all covered by tests):
      - "- **🔴 Critical:** input is not sanitized" -> 1   (bold+emoji; "not" is mid-description)
      - "- [High] - missing await"                  -> 1   (bracketed label)
      - "Overall looks good, but:\n- Critical: X"    -> 1   (polite filler can't mask the bullet)
      - "No Critical issues found" / "None found"    -> 0   (does not start with a severity token)
      - "- High quality code throughout"             -> 0   (no delimiter after the word)
      - "## 🔴 Critical Findings" (heading)          -> 0   ('#' is not decoration)
    """
    count = 0
    PRE = r"""[-*+>\[\s`'"]*"""   # leading markdown decoration; NOT '#', so headings are excluded
    emoji = rf"^{PRE}(🔴|🟠|🟡)"
    # A severity word wrapped in optional bold/bracket, then (after optional bold/bracket) a delimiter.
    label = rf"^{PRE}(Critical|High|Medium)\b[\]*]*\s*[:\-–—]"
    for line in text.splitlines():
        s = line.strip()
        if re.match(emoji, s) or re.match(label, s, re.I):
            count += 1
    return count


def call_cost(rec):
    """(usd, estimated?) for one raw call. Real from OpenRouter; estimate from PRICES for Gemini.

    Returns (None, False) when neither is available so 'unknown' stays distinct from a real 0.0.
    """
    if rec.get("total_cost") is not None:
        return float(rec["total_cost"]), False
    spec = rec.get("spec", "")
    name = spec.split(":", 1)[1] if spec.startswith("gemini:") else spec
    price = PRICES.get(name)
    if price:
        return (rec.get("prompt_tokens", 0) / 1e6 * price[0]
                + rec.get("completion_tokens", 0) / 1e6 * price[1]), True
    return None, False


def load_raw(raw_dir):
    """Every raw record, grouped by model id. Skips malformed / keyless files loudly."""
    by_model = defaultdict(list)
    for path in sorted(glob.glob(os.path.join(raw_dir, "*.json"))):
        try:
            with open(path, encoding="utf-8") as fh:
                r = json.load(fh)
        except (json.JSONDecodeError, OSError) as e:
            print(f"  skip malformed raw file {os.path.basename(path)}: {e}")
            continue
        if not r.get("model") or not r.get("fixture"):
            print(f"  skip {os.path.basename(path)}: missing model/fixture key")
            continue
        r.setdefault("trial", 1)
        by_model[r["model"]].append(r)
    return by_model


def score_model(mid, recs, bugs, clean_fixtures, strict):
    """Aggregate one model across all its trials into a row + a per-bug detection-rate map."""
    spec = recs[0].get("spec", "")
    # fixture -> {trial: record}
    by_fix = defaultdict(dict)
    for r in recs:
        by_fix[r["fixture"]][r.get("trial", 1)] = r

    # Detection RATE per bug across that fixture's trials.
    frac = {}
    for b in bugs:
        trials = by_fix.get(b["fixture"], {})
        if not trials:
            frac[b["id"]] = 0.0
            continue
        det = sum(1 for r in trials.values() if detect(b, r.get("text") or "", b["fixture"], strict))
        frac[b["id"]] = det / len(trials)

    total_weight = sum(WEIGHT[b["severity"]] for b in bugs)
    found_weight = sum(WEIGHT[b["severity"]] * frac[b["id"]] for b in bugs)

    # False positives: mean per-trial count over the clean control(s).
    fp_samples = [false_positives(r.get("text") or "")
                  for fx in clean_fixtures for r in by_fix.get(fx, {}).values()]
    fp = round(sum(fp_samples) / len(fp_samples), 2) if fp_samples else 0

    # Cost to review the fixture set ONCE (total across calls / number of trials).
    ntrials = len({r.get("trial", 1) for r in recs}) or 1
    known = [call_cost(r) for r in recs]
    real_or_est = [(c, e) for c, e in known if c is not None]
    cost = round(sum(c for c, _ in real_or_est) / ntrials, 6) if real_or_est else None
    cost_estimated = bool(real_or_est) and all(e for _, e in real_or_est)

    latencies = [r.get("latency_ms", 0) for r in recs]
    errors = [f"{r['fixture']} t{r.get('trial', 1)}: {r['error']}" for r in recs if r.get("error")]

    return {
        "model": mid, "spec": spec, "ntrials": ntrials,
        "detection_pct": round(100 * found_weight / total_weight, 1),
        "detected_maj": sum(1 for b in bugs if frac[b["id"]] >= 0.5),
        "missed_crit": sum(1 for b in bugs if b["severity"] == "Critical" and frac[b["id"]] < 0.5),
        "flaky": sum(1 for b in bugs if 0 < frac[b["id"]] < 1),
        "false_positives": fp,
        "avg_latency_ms": int(sum(latencies) / len(latencies)) if latencies else 0,
        "cost": cost, "cost_estimated": cost_estimated,
        "prompt_tokens": sum(r.get("prompt_tokens", 0) for r in recs),
        "completion_tokens": sum(r.get("completion_tokens", 0) for r in recs),
        "errors": errors, "frac": frac,
    }, frac


def combinations_table(rows, frac_by_model, bugs, total_weight):
    """Union coverage + combined cost/FP for every 1-3 model set. Answers 'which set is best value'.

    A bug's coverage by a set is the BEST (max) detection rate any member achieves for it, so a set
    covers what its strongest member on each bug covers - the real benefit of a diverse panel. A
    Critical counts as missed by the set only if no member majority-detects it. Ranked by
    missed-Criticals, then union coverage, then combined cost.
    """
    cost_by = {r["model"]: r["cost"] for r in rows}
    fp_by = {r["model"]: r["false_positives"] for r in rows}
    crit = [b for b in bugs if b["severity"] == "Critical"]
    combos = []
    for size in (1, 2, 3):
        for combo in itertools.combinations(frac_by_model, size):
            uw = sum(WEIGHT[b["severity"]] * max(frac_by_model[m][b["id"]] for m in combo) for b in bugs)
            member_costs = [cost_by.get(m) for m in combo]
            combos.append({
                "members": list(combo), "size": size,
                "union_pct": round(100 * uw / total_weight, 1),
                "missed_crit": sum(1 for b in crit if max(frac_by_model[m][b["id"]] for m in combo) < 0.5),
                "cost": None if any(c is None for c in member_costs) else round(sum(member_costs), 6),
                "false_positives": round(sum(fp_by.get(m, 0) for m in combo), 2),
            })
    combos.sort(key=lambda c: (c["missed_crit"], -c["union_pct"],
                               c["cost"] if c["cost"] is not None else 9e9,
                               c["false_positives"], c["size"]))
    return combos


def fmt_cost(cost, estimated):
    if cost is None:
        return "n/a"
    return f"{'~' if estimated else ''}${cost:.4f}"


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
    n_buggy = len(MANIFEST["fixtures"]) - len(clean_fixtures)
    total_weight = sum(WEIGHT[b["severity"]] for b in bugs)
    n_crit = sum(1 for b in bugs if b["severity"] == "Critical")

    by_model = load_raw(raw_dir)
    rows, frac_by_model = [], {}
    for mid, recs in by_model.items():
        row, frac = score_model(mid, recs, bugs, clean_fixtures, strict)
        rows.append(row)
        frac_by_model[mid] = frac
    rows.sort(key=lambda x: (-x["detection_pct"], x["cost"] if x["cost"] is not None else 9e9))

    combos = combinations_table(rows, frac_by_model, bugs, total_weight) if frac_by_model else []
    trials = max((r["ntrials"] for r in rows), default=1)

    scorecard = {
        "run_id": run_id, "strict": strict, "trials": trials, "total_bugs": len(bugs),
        "total_weight": total_weight, "n_critical": n_crit,
        "models": rows, "combinations": combos,
    }
    with open(os.path.join(run_dir, "scorecard.json"), "w", encoding="utf-8") as fh:
        json.dump(scorecard, fh, indent=2)

    # --- Per-run RESULTS.md -------------------------------------------------------------------
    out = [f"# Benchmark run `{run_id}`", ""]
    meta_path = os.path.join(run_dir, "meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
        rt = meta.get("routing", {})
        out.append(f"Trials: {meta.get('trials', trials)} · temperature 0 · "
                   f"routing hosts=`{rt.get('openrouter_hosts') or 'any'}` sort=`{rt.get('sort')}` "
                   f"quant=`{rt.get('quantizations') or 'any'}` zdr=`{rt.get('zdr')}` · "
                   f"slugs validated: {meta.get('slugs_validated')}")
        out.append("")
    out += [
        f"Scored against {len(bugs)} planted bugs ({n_crit} Critical) across {n_buggy} buggy "
        f"fixtures + {len(clean_fixtures)} clean control. Detection is severity-weighted "
        f"(Critical {WEIGHT['Critical']:g} / High {WEIGHT['High']:g} / Medium {WEIGHT['Medium']:g} "
        f"/ Low {WEIGHT['Low']:g}). {'STRICT (line match required). ' if strict else ''}"
        f"{'`Flaky` = bugs found in some but not all trials.' if trials > 1 else ''}",
        "",
        "## Per-model",
        "",
        "| Rank | Model | Detection | Bugs (maj) | Missed Crit | Flaky | False+ | Avg latency | Cost/run | Notes |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for i, r in enumerate(rows, 1):
        note = f"⚠️ {len(r['errors'])} call error(s)" if r["errors"] else ""
        out.append(
            f"| {i} | {r['model']} | {r['detection_pct']}% | {r['detected_maj']}/{len(bugs)} | "
            f"{r['missed_crit']} | {r['flaky'] if trials > 1 else '-'} | {r['false_positives']} | "
            f"{r['avg_latency_ms']} ms | {fmt_cost(r['cost'], r['cost_estimated'])} | {note} |")

    # Best-value combinations (union coverage per pound) — the actual "one model vs a panel" answer.
    if combos:
        out += [
            "", "## Best-value combinations (union coverage of 1–3 models)",
            "",
            "Coverage is the union across the set; cost is the sum of members. Ranked by missed "
            "Criticals, then coverage, then cost.",
            "",
            "| Rank | Models | Size | Union detection | Missed Crit | Comb. cost/run | Comb. false+ |",
            "|---|---|---|---|---|---|---|",
        ]
        for i, c in enumerate(combos[:12], 1):
            cc = "n/a" if c["cost"] is None else f"${c['cost']:.4f}"
            out.append(f"| {i} | {', '.join(c['members'])} | {c['size']} | {c['union_pct']}% | "
                       f"{c['missed_crit']} | {cc} | {c['false_positives']} |")
        for size in (1, 2, 3):
            best = next((c for c in combos if c["size"] == size), None)
            if best:
                cc = "n/a" if best["cost"] is None else f"${best['cost']:.4f}"
                out.append(f"\n- **Best {size}-model set:** {', '.join(best['members'])} — "
                           f"{best['union_pct']}% detection, {best['missed_crit']} missed Crit, {cc}/run.")

    out += ["", "`~` = estimated cost (direct-Gemini token estimate); un-prefixed = real OpenRouter USD.",
            "", "See `scorecard.json` for the per-bug detection matrix and `raw/` for full model output."]
    with open(os.path.join(run_dir, "RESULTS.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")

    # --- Rolled-up index ----------------------------------------------------------------------
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
        with open(sc_path, encoding="utf-8") as fh:
            sc = json.load(fh)
        top = sc["models"][0] if sc.get("models") else None
        best = f"best single: **{top['model']}** ({top['detection_pct']}%)" if top else "no models"
        bestset = ""
        if sc.get("combinations"):
            b = sc["combinations"][0]
            bcost = "n/a" if b["cost"] is None else f"${b['cost']:.4f}"
            bestset = f"; best value: {', '.join(b['members'])} ({b['union_pct']}%, {bcost})"
        idx.append(f"- [`{rid}`](results/{rid}/RESULTS.md) — {len(sc.get('models', []))} models, {best}{bestset}")
    with open(os.path.join(HERE, "RESULTS.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(idx) + "\n")

    print(f"Scored {len(rows)} models ({trials} trial(s)) -> {os.path.join(run_dir, 'RESULTS.md')}")
    for r in rows:
        print(f"  {r['detection_pct']:5.1f}%  {r['detected_maj']}/{len(bugs)}  "
              f"missCrit={r['missed_crit']}  FP={r['false_positives']}  {r['model']}")
    if combos:
        b = combos[0]
        print(f"  best value: {', '.join(b['members'])} -> {b['union_pct']}% "
              f"({b['missed_crit']} missed Crit, cost={fmt_cost(b['cost'], False)})")


if __name__ == "__main__":
    main()
