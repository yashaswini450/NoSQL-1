#!/bin/bash
# One-shot setup + run + commit-back script for Pop!_OS (Debian/Ubuntu-based).
#
# Usage:
#   cd ps1
#   ./bootstrap_and_run.sh
#
# What it does:
#   1. Installs OS packages: PostgreSQL, build tools, Python.
#   2. Creates a PostgreSQL role matching your Linux username (if missing).
#   3. Builds dbgen and creates+loads tpch_sf{1,2,4,8} databases.
#   4. Runs the benchmark (3 repeats/query) and generates plots.
#   5. Commits scaling_results.csv + plots/ + summary_stats.csv and pushes
#      to origin main.
#
# Re-running is safe: each step is idempotent (databases are dropped and
# recreated, dbgen build is a no-op if already built).
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "### 1. Installing OS packages (requires sudo password) ###"
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib build-essential gcc make \
    python3 python3-pip python3-venv git

echo "### 2. Ensuring PostgreSQL is running and you have a login role ###"
sudo systemctl enable --now postgresql
CURRENT_USER="$(whoami)"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${CURRENT_USER}'" | grep -q 1; then
    sudo -u postgres createuser --superuser "${CURRENT_USER}"
    echo "Created PostgreSQL superuser role '${CURRENT_USER}'"
fi

echo "### 3. Building dbgen ###"
(cd tpch-kit/dbgen && make)

echo "### 4. Setting up Python environment ###"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "### 5. Generating/loading data for SF 1, 2, 4, 8 ###"
./setup_scaling.sh

echo "### 6. Running benchmark (3 repeats/query) ###"
python3 run_benchmark.py --scale-factors 1 2 4 8 --repeats 3

echo "### 7. Generating plots and summary stats ###"
python3 plot_results.py

deactivate

echo "### 8. Committing and pushing results to origin main ###"
cd "$REPO_ROOT"
git add ps1/scaling_results.csv ps1/plots/
if git diff --cached --quiet; then
    echo "Nothing new to commit."
else
    git commit -m "results(performance): add scaling benchmark raw results and plots"
    git push origin main
fi

echo "### Done. Raw results: ps1/scaling_results.csv, plots: ps1/plots/ ###"
