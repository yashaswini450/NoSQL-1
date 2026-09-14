#!/usr/bin/env python3
"""Independent reference implementation of the Part-3 query specification.

Used ONLY to cross-check pipeline.sh output (test oracle, not a deliverable).
Implements the same spec directly in Python stdlib, streaming row by row.

Usage: python3 oracle.py INPUT.tsv
  stdout : the expected pipeline result table (same format as pipeline.sh)
  stderr : one JSON line with row accounting (rows/rejected/reasons/filtered)
"""
import json
import re
import sys
sys.stdout.reconfigure(newline="\n")   # LF output so diff vs pipeline works
from datetime import date

DATE_MIN = "2026-01-01"
QTY_MIN = 2
REV_MIN = 100000.0
TOP_N = 10

RE_QTY = re.compile(r"[0-9]+\Z")
RE_PRICE = re.compile(r"[0-9]+(\.[0-9]+)?\Z")
RE_DATE = re.compile(r"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\Z")


def is_valid_date(s):
    if not RE_DATE.match(s):
        return False
    y, m, d = int(s[0:4]), int(s[5:7]), int(s[8:10])
    if y == 0:  # proleptic Gregorian: year 0 is a leap year (div by 400)
        leap = True
    else:
        try:
            date(y, m, d)  # independent calendar check
            return True
        except ValueError:
            return False
    if not (1 <= m <= 12):
        return False
    maxd = 29 if leap and m == 2 else (28 if m == 2 else
                                       30 if m in (4, 6, 9, 11) else 31)
    return 1 <= d <= maxd


def main(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        header = f.readline().rstrip("\n")
        if header.startswith("\ufeff"):
            header = header[1:]
        if header.endswith("\r"):
            header = header[:-1]
        names = header.split("\t")
        cols = {n.lower(): i for i, n in enumerate(names)}
        need = ("category", "quantity", "price", "date")
        if not all(n in cols for n in need):
            sys.exit("oracle: header missing required columns")
        ci, qi, pi, di = (cols[n] for n in need)
        nc = len(names)

        rows = rejected = filtered = emitted = 0
        rej = {}
        groups = {}  # category -> [count, revenue]

        for line in f:
            raw = line.rstrip("\n")
            if raw.endswith("\r"):
                raw = raw[:-1]
            rows += 1

            def bad(reason):
                nonlocal rejected
                rejected += 1
                rej[reason] = rej.get(reason, 0) + 1

            if raw == "":
                bad("empty_line")
                continue
            fields = raw.split("\t")
            if len(fields) != nc:
                bad("missing_field" if len(fields) < nc else "extra_field")
                continue
            q, p, d = fields[qi], fields[pi], fields[di]
            if not RE_QTY.match(q):
                bad("bad_quantity")
                continue
            if not RE_PRICE.match(p):
                bad("bad_price")
                continue
            if not is_valid_date(d):
                bad("bad_date")
                continue
            if d < DATE_MIN or int(q) <= QTY_MIN:
                filtered += 1
                continue
            emitted += 1
            g = groups.setdefault(fields[ci], [0, 0.0])
            g[0] += 1
            g[1] += int(q) * float(p)

    out = [(c, v[0], v[1]) for c, v in groups.items() if v[1] > REV_MIN]
    out.sort(key=lambda t: (-t[2], t[0]))
    print("category\ttransactions\trevenue")
    for c, n, r in out[:TOP_N]:
        print(f"{c}\t{n}\t{r:.2f}")

    stats = {"input_data_rows": rows, "rejected_total": rejected,
             "where_filtered": filtered, "passed_where": emitted,
             "reasons": rej}
    print(json.dumps(stats), file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1])
