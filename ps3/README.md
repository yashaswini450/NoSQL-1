# Part 3 — Unix Data-Processing Pipeline

A streaming implementation of the assignment's SQL query over
`transactions.tsv` using **only bash + standard Unix tools** (`awk`, `sort`,
`head`, `cat`). No database, no dataframe library, and the input is never
loaded into memory: every stage consumes and produces lines through pipes.

## Files

| file | purpose |
|---|---|
| `pipeline.sh` | the pipeline itself. `./pipeline.sh INPUT.tsv [REJECT_LOG]` |
| `generate_transactions` | course-provided data generator, shipped here so the benchmark reproduces standalone (the driver also accepts `--generator PATH`) |
| `run_tests.sh` | driver: functional demo + known-answer checks, dataset generation at target sizes, timing benchmark. `./run_tests.sh --help` |
| `results/` | outputs written by the driver (`functional_demo.txt`, `benchmark_results.txt`, `scalability_results.csv`, sample reject logs) |

## The query

```sql
SELECT   category,
         COUNT(*)                AS transactions,
         SUM(quantity * price)   AS revenue
FROM     transactions
WHERE    date >= '2026-01-01'
  AND    quantity > 2
GROUP BY category
HAVING   SUM(quantity * price) > 100000
ORDER BY revenue DESC
LIMIT    10;
```

## Schema note

The schema used throughout is the one specified in the problem statement and
produced by `generate_transactions`:

    transaction_id  date  category  quantity  price      (TAB-separated)

(The supplied `transactions.tsv` / `transactions_malformed.tsv` samples use a
different, inconsistent 6-column layout and are **not used**. Every test
dataset in the driver is generated with `generate_transactions`, plus one
hand-crafted known-answer file in this same schema.)

`pipeline.sh` still resolves column **positions from the header row**
(name → index, like looking up ordinals in a table's catalog) instead of
hardcoding `$1..$5`, and validates that each row has exactly as many fields
as the header. This keeps the schema in one place and makes the pipeline
robust to column reordering; a header missing any of
`category/quantity/price/date` is a hard error before any data is processed.

| SQL clause | Pipeline stage | Implementation | Notes |
|---|---|---|---|
| `FROM transactions` | input | `s1 < "$INPUT"` (redirect into awk) | awk streams the file line by line; the header (`NR==1`) is consumed as schema metadata |
| *(catalog lookup)* | schema resolution | `read -r header` + awk name→index map | one-time, first line only |
| *(data quality — no SQL equivalent)* | validation | awk structural + type checks | malformed rows are logged and skipped, never fatal (see below) |
| `WHERE date >= '2026-01-01'` | row filter | awk `if (d < date_min) next` | ISO-8601 dates compare correctly as **plain strings**, so lexicographic = chronological |
| `AND quantity > 2` | row filter | awk `if (q + 0 <= qty_min) next` | numeric comparison |
| projection of `category`, `quantity*price` | projection | awk `printf "%s\t%.4f\n"` | emits one line per surviving row; `printf` (not `print`) because `print` stringifies through `CONVFMT="%.6g"` and would corrupt values ≥ 10⁶ (e.g. `1234567.89` → `1.23457e+06`) |
| `GROUP BY category` | grouping | awk associative array key `$1` | memory is O(#distinct categories), not O(#rows) |
| `COUNT(*)` | counter | `cnt[$1]++` | |
| `SUM(quantity * price)` | accumulator | `rev[$1] += $2` | running sum per group |
| `HAVING SUM(quantity*price) > 100000` | post-aggregation filter | awk `($3 + 0) > rev_min` | by now the stream is one line per group, so a row filter on the aggregate column implements HAVING exactly |
| `ORDER BY revenue DESC` | sort | `sort -t '\t' -k3,3nr -k1,1` | `-t` TAB is mandatory: categories contain spaces (`Pet Supplies`); the secondary key (category ASC) only breaks exact revenue ties, making output deterministic |
| `LIMIT 10` | head | `head -n 10` | after `sort`, so it keeps the top 10 |
| `SELECT` list + column header | final projection | awk `printf` | runs **after** `head`, so the header line can never be counted by LIMIT; revenue formatted to 2 decimals |

Why not `cut`/`grep`/`uniq`? `cut` cannot validate types, `grep` cannot
combine two fields in a predicate, and `sort | uniq -c` can count groups but
cannot sum `quantity*price` per group — which is exactly what awk's
associative arrays are for. (`cut`/`grep` would be reasonable for simpler
one-column selections.)

### The pipeline, as actually wired in `pipeline.sh`

```
INPUT.tsv
   │
   ▼  s1  awk    validate (reject log)  →  WHERE  →  project "category ⇥ qty*price"
   ▼  s2  awk    GROUP BY: cnt[cat]++ ; rev[cat] += …   (END: one line per category)
   ▼  s3  awk    HAVING  revenue > 100000
   ▼  s4  sort   ORDER BY revenue DESC (ties: category ASC)
   ▼  s5  head   LIMIT 10
   ▼  s6  awk    SELECT formatting: column header + %.2f money
```

Every arrow is a pipe. `pipeline.sh -n N` runs only the first N stages —
used by the driver to attribute time to each stage. Memory stays
O(#categories) end to end: `sort` only ever sees one line per category.

## Malformed-record handling

Rows are rejected for the **first** rule they violate (reason counts are
mutually exclusive), logged to `REJECT_LOG` (default
`INPUT.tsv.rejects.log`) with line number + reason + raw row, and never
counted in any aggregate. The pipeline never terminates because of a bad
row.

| reason | rule |
|---|---|
| `empty_line` | blank line |
| `missing_field` / `extra_field` | field count ≠ header's field count |
| `bad_quantity` | quantity not an unsigned integer (`bad`, `-3`, `3.0`, ` 3`) |
| `bad_price` | price not a plain decimal (`N/A`, `1e3`, `10.`, empty, negative) |
| `bad_date` | not a real `YYYY-MM-DD` calendar date — regex + month/day ranges incl. leap years (`invalid-date`, `2026-99-99`, `2026-02-30`, `2026-4-05`) |

The log ends with a summary block (`input_data_rows`, `rejected_total`,
per-reason counts, `where_filtered`, `passed_where`) so rejected-row
accounting is auditable:

```
# line_no	reason	row
12	bad_quantity	121	P21	Electronics	bad	10000	2026-06-25
13	bad_price	122	P22	Grocery	4		2026-06-26
...
# ---- summary ----
input_data_rows	14
rejected_total	4
...
```

## Correctness verification

* The driver (`run_tests.sh`, Section A) runs a **known-answer test** on a
  25-row hand-crafted file in the problem-statement schema — 14 malformed
  rows, one per reject rule; WHERE boundaries `2026-01-01` in /
  `2025-12-31` and `2024-02-29` out; quantity boundary 3 in / 2 out; HAVING
  boundary 100000.00 out / 100000.004 in — and compares both the output
  table and the full row accounting (rejected / WHERE-filtered / passed)
  against hand-computed values, failing loudly on mismatch.
* During development the pipeline was additionally cross-checked against an
  independent Python stdlib reference implementation of the same spec
  (streaming `csv` + `datetime`, i.e. a different regex/calendar engine).
  Output tables and full row accounting matched exactly on 6 corpora: the
  known-answer file, a 50 000-row generator file, the same file with ~1 %
  malformed rows (579 rejects across all 5 generator kinds), a
  CRLF-line-ends copy, a permuted-column-header copy and a UTF-8-BOM copy.
  Reproduce with: `python3 verify_oracle.py INPUT.tsv` (prints the expected
  table; diff it against `pipeline.sh` output) and
  `python3 verify_stats.py REJECT_LOG` after feeding its JSON stats — both
  scripts are independent of `pipeline.sh` and of each other.

## Benchmark methodology

* Datasets: `generate_transactions --records N --seed 42`, targeted at
  100 / 250 / 500 / 1000 **decimal MB** (10⁶ bytes). The driver measures
  the generator's average row size with a 20 000-row probe, estimates `N`,
  generates, checks the **actual** size, and regenerates with a corrected
  `N` if it is more than ±2 % off target (it converged to ≤0.1 % on the
  first correction in our runs).
* Timing: wall-clock via bash's `$EPOCHREALTIME` (microsecond resolution,
  no output parsing), **best of 3 runs** per size; one extra run per
  dataset is shown under the classic `time` keyword. Same machine, same
  pipeline configuration for all sizes; environment auto-recorded in
  `results/benchmark_results.txt`.
* Datasets are written to `~/nosql_pipeline_bench` (outside the OneDrive
  folder — syncing 1.85 GB of test data would skew every measurement).
  `./run_tests.sh --clean` removes them.

## Results

### Environment (recorded by the driver, `results/benchmark_results.txt`)

```
date        : Mon Sep 14 19:01:53 BST 2026
os          : Linux 6.18.33.2-microsoft-standard-WSL2 (WSL2 on Windows 11,
              AMD Ryzen 9 6900HS)
cpu threads : 16          bash        : 5.2.21
awk         : GNU Awk 5.2.1          sort : GNU coreutils 9.4
python      : 3.12.3 (generator)     timing : $EPOCHREALTIME, best of 3
```

### Dataset generation (Section B of the driver)

The 20 000-record probe measured **42 bytes/row** (~2.38 M records per
100 MB). Every size needed exactly one self-correction pass and then landed
within ±0.0 % of target, e.g. 1000 MB target → 1 000 002 218 bytes actual
(23 301 397 records).

### Full-pipeline timing (best of 3)

| Input size (MB) | Records | Best time (s) | Throughput (MB/s) |
|---:|---:|---:|---:|
| 100  | 2 330 158  | 3.845  | 26.0 |
| 250  | 5 825 347  | 9.555  | 26.2 |
| 500  | 11 650 595 | 19.509 | 25.6 |
| 1000 | 23 301 397 | 42.381 | 23.6 |

One 1000 MB run under the classic `time`: `real 0m45.7s / user 0m46.3s /
sys 0m1.2s`.

### Per-stage breakdown (1000 MB, single runs — run-to-run noise is ±2–3 s)

| Configuration | Time (s) |
|---|---:|
| `cat FILE > /dev/null` (raw read, page-cached) | 0.093 |
| stage 1 only — validation + WHERE + projection | 42.183 |
| stages 1–2 — … + GROUP BY / aggregation | 45.876 |
| stages 1–3 — … + HAVING | 40.051 |
| full pipeline — … + sort + LIMIT + formatting | 44.487 |

Sample outputs (valid and malformed datasets, known-answer test) are in
`results/functional_demo.txt`.

## Analysis

**Execution time scales linearly with input size.** Doubling the data
doubles the time (250 → 500 MB: 9.555 → 19.509 s, ×2.04; 500 → 1000 MB:
19.509 → 42.381 s, ×2.17), and the whole 10× size increase costs ×11.0.
Throughput stays at ~24–26 MB/s ≈ 550 000 rows/s, with a slight dip at
1 GB (23.6 MB/s, ~9 % below the smaller sizes) — consistent with
page-cache/WSL2 effects rather than a change in algorithmic behaviour.
This is the expected profile: every row is touched exactly once by stage 1
and (for the ~45 % of rows that survive WHERE) once more by stage 2, so the
work is O(n); the remaining stages work on at most one line per category.

**Stage 1 (validation + WHERE + projection) is the bottleneck, by a wide
margin.** It accounts for ~42 s of the ~43–45 s total on 1 GB (~90–95 %);
adding aggregation, HAVING, sort, LIMIT and formatting changes the total by
at most a few seconds — within run-to-run noise, because after stage 1 the
stream is only ≤ 20 lines (one per category), so `sort` sorts 20 keys, and
HAVING/LIMIT/formatting are microseconds. Stage 2 is the only other O(rows)
pass, but it reads the already-projected, WHERE-reduced stream (~45 % of
rows, two narrow columns), which is why its marginal cost is small.
Stage 1 is CPU-bound, not I/O-bound: the raw-read baseline is 0.093 s
(page-cached), and `user 46.3 s ≈ real 45.7 s` in the `time` run shows a
single core saturated with no I/O waiting. The per-row cost is interpreted
awk work: field splitting on tabs, 2–3 regex tests (integer quantity,
decimal price, date format), the calendar-validity check, comparisons and a
`printf` — roughly 1.8 µs per row.

**What would change the picture.** (a) A higher-cardinality GROUP BY key
(millions of groups instead of 20) would make the awk hash table the memory
bottleneck and move real work into `sort` (O(g log g), external spill).
(b) Parallelism: `split` the input and run one awk per chunk, then merge
partial aggregates — the aggregation is associative, so the merge is
trivial — but that is hand-built parallelism the shell does not give you
for free. (c) A faster awk (mawk is typically 2–4× faster than gawk here)
or rewriting stage 1 in C would cut the dominant cost proportionally.

**Streaming Unix pipeline vs a real database for this query.**

| Aspect | Unix pipeline | Database |
|---|---|---|
| Setup | zero — runs directly on the TSV | load data, define schema/types |
| Parsing cost | re-parses and re-validates text on **every** run (this is most of our 42 s) | parses once at load; stores typed columns; predicates evaluate on integers/numerics |
| Access path | always a full scan | indexes / zone maps / partition pruning can skip data |
| Parallelism | one core per stage; manual `split`+merge for more | parallel query plans out of the box |
| Memory model | group hash table must fit in RAM (fine for 20 groups; the first wall for high cardinality) | hash aggregation spills to disk gracefully |
| Optimizer | fixed, hand-ordered stages | cost-based planning from statistics |
| Semantics | double precision, no transactions, no crash recovery, no concurrent writers | DECIMAL types, ACID, concurrency, durability |
| Transparency & composability | every stage visible, re-runnable, pipes into anything (`gnuplot`, `mail`) | opaque without the engine |

For a one-off analytical scan over a few GB on a laptop, the pipeline is
the right tool: zero setup, constant memory (for low-cardinality groups),
linear scaling, ~42 s for 1 GB, and every intermediate value inspectable.
The database wins as data volume, query complexity (joins), concurrency, or
repeated querying grows — it pays once, at load time, for what the shell
pays on every run.
uced
    files behave identically.
