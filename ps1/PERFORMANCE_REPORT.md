# TPC-H PostgreSQL Scaling Study — Performance Report

Person 2 deliverable: automation, timing, raw results, plots, scaling
analysis, and interpretation for the TPC-H benchmark set (Q1-Q22) run
against PostgreSQL at scale factors 1, 2, 4, and 8.

## 1. Methodology

- **Schema & data**: `setup_scaling.sh` builds one database per scale
  factor (`tpch_sf1`, `tpch_sf2`, `tpch_sf4`, `tpch_sf8`), generating data
  with `dbgen` and loading it via `load_data.sql`.
- **Timing**: `run_benchmark.py` executes each of the 22 TPC-H queries
  against each scale-factor database, `--repeats 3` times per query, and
  appends every individual run to `scaling_results.csv` (long format:
  `scale_factor, query, run, time_seconds`). Running each query multiple
  times and later taking the mean/median smooths out caching and OS
  scheduling noise from a single cold/hot run.
- **Environment**: <TODO — fill in on Pop!_OS: PostgreSQL version,
  `work_mem`/`shared_buffers` settings if changed from default, CPU/RAM/disk
  (SSD vs HDD), whether the OS cache was dropped between scale factors>.
- **Aggregation & plots**: `plot_results.py` reads the raw CSV, computes
  per-(scale factor, query) mean/median/std into `plots/summary_stats.csv`,
  and produces:
  - `plots/total_time_vs_scale.png` — total time across all 22 queries vs
    scale factor (log-log).
  - `plots/per_query_vs_scale.png` — one small subplot per query showing
    how its time grows with scale factor.
  - `plots/scaling_efficiency.png` — each query's time normalized to its
    SF=1 baseline, plotted against the ideal linear-scaling reference line.

## 2. How to reproduce

```bash
cd ps1
pip install -r requirements.txt
./run_full_study.sh
```

This runs the full pipeline: data generation/loading → timed benchmark →
plots. Individual stages can also be run separately (`./setup_scaling.sh`,
`python3 run_benchmark.py`, `python3 plot_results.py`).

## 3. Raw results

<TODO — after running on Pop!_OS, note where `scaling_results.csv` and
`plots/summary_stats.csv` ended up, and paste the total-time-per-scale-factor
table from `plot_results.py`'s console output here.>

## 4. Scaling analysis

<TODO — fill in once real numbers are available. Structure to follow:>

- **Overall trend**: Does total execution time grow linearly, sub-linearly,
  or super-linearly with scale factor? Compare against the "ideal linear
  scaling" reference line in `scaling_efficiency.png`.
- **Best/worst scaling queries**: Identify which queries stay closest to
  linear (typically simple scans/aggregations over `lineitem`, e.g. Q1, Q6)
  and which degrade faster than linear (typically queries with large
  hash/merge joins or sorts that spill to disk once working sets exceed
  `work_mem`, e.g. Q9, Q17, Q21).
- **Bottleneck reasoning**: Tie degradation to mechanism — sequential scan
  cost scales with table size (~linear), but sort/hash-join memory
  pressure and index maintenance cost can scale worse than linear as data
  grows, especially without appropriate indexes or `ANALYZE` statistics.

## 5. Interpretation / conclusion

<TODO — 1-2 paragraph summary once data is in: what does this imply about
using an unoptimized default-config PostgreSQL for growing TPC-H-style
workloads, and what tuning (indexes, `work_mem`, partitioning) would you
expect to help most based on which queries scaled worst.>
