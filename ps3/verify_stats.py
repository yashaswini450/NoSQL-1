#!/usr/bin/env python3
"""Compare pipeline.sh's reject-log summary against the oracle's JSON stats.
Usage: python3 cmp_stats.py REJECT_LOG ORACLE_STATS_JSON
Prints OK or a mismatch description; exit code 1 on mismatch."""
import json
import sys

log, stats_path = sys.argv[1], sys.argv[2]
log_stats = {}
with open(log) as f:
    in_summary = False
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("# ---- summary ----"):
            in_summary = True
            continue
        if in_summary and "\t" in line and not line.startswith("#"):
            k, v = line.split("\t", 1)
            log_stats[k] = v

oracle = json.load(open(stats_path))
want = {
    "input_data_rows": str(oracle["input_data_rows"]),
    "rejected_total": str(oracle["rejected_total"]),
    "where_filtered": str(oracle["where_filtered"]),
    "passed_where": str(oracle["passed_where"]),
}
for r, n in sorted(oracle["reasons"].items()):
    want["rejected_" + r] = str(n)

bad = [f"{k}: pipeline={log_stats.get(k, '<missing>')} oracle={v}"
       for k, v in sorted(want.items()) if log_stats.get(k) != v]
extra = [k for k in log_stats if k not in want and k.startswith("rejected_")]
if extra:
    bad.append(f"pipeline logged reasons the oracle did not: {extra}")
if bad:
    print("MISMATCH: " + "; ".join(bad))
    sys.exit(1)
print("stats OK")
