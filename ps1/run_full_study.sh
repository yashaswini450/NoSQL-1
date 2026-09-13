#!/bin/bash
# One-shot entry point for the performance/scaling study: generate+load data
# for every scale factor, run the timed benchmark, then produce plots.
# Run on Linux (Pop!_OS) with PostgreSQL, dbgen build deps, and
# `pip install -r requirements.txt` already done.
set -euo pipefail
cd "$(dirname "$0")"

./setup_scaling.sh
python3 run_benchmark.py --scale-factors 1 2 4 8 --repeats 3
python3 plot_results.py
