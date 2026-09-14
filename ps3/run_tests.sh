#!/usr/bin/env bash
#
# ============================================================================
# run_tests.sh - driver for the Part-3 Unix pipeline
# ============================================================================
#
# What it does (assignment requirements 5a/5b/5c):
#   A. Functional demo (all data in the problem-statement schema, generated
#      by generate_transactions)
#      - runs pipeline.sh on a small hand-crafted known-answer file
#        (25 rows; 14 malformed, one per reject rule; WHERE/HAVING boundary
#        cases) and checks output and row accounting against hand-computed
#        values
#      - runs pipeline.sh on 100000 generated records (valid) and 100000
#        generated records with --malformed (~1% bad rows), showing
#        outputs and reject-log summaries
#   B. Dataset generation at target sizes
#      - estimates the --records value needed for each target size from a
#        measured average row size, generates, verifies the ACTUAL file
#        size, and regenerates with a corrected record count if it is more
#        than 2% off target
#   C. Timing benchmark
#      - times the FULL pipeline on every dataset (best of N runs),
#        plus a raw-read baseline and a per-stage breakdown on the largest
#        dataset, and writes a size-vs-time results table
#
# USAGE
#     ./run_tests.sh [options]
#
#     --sizes "100 250 500 1000"  target sizes in MB (default)
#     --runs N                    timed repetitions per size (default 3;
#                                 the best time is reported)
#     --data-dir DIR              where benchmark datasets are stored.
#                                 Default: $USERPROFILE/nosql_pipeline_bench
#                                 (i.e. C:/Users/<you>/nosql_pipeline_bench -
#                                 deliberately OUTSIDE the OneDrive-synced
#                                 project folder: syncing 1.85 GB of test
#                                 data would skew every measurement)
#     --results-dir DIR           where result files go (default: ./results)
#     --skip-gen                  reuse existing datasets, skip generation
#     --quick                     fast smoke test: sizes "5 10", 1 timed run
#     --clean                     delete the data dir and exit
#
# TIMING METHOD
#     Wall-clock time from bash's $EPOCHREALTIME (microsecond clock, no
#     subprocess, no output parsing).  One run per dataset is additionally
#     shown under the classic `time` keyword for reference.  This script
#     measures REAL (elapsed) time, which is what a streaming pipeline is
#     bound by.
#
# REPRODUCIBILITY
#     All datasets are generated with --seed 42.  The generator's row size
#     is essentially constant, so the record estimate is self-correcting.
# ============================================================================

set -eu
export LC_ALL=C        # deterministic sorting/formatting everywhere

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"       # all relative paths below resolve from here

# ---- defaults ---------------------------------------------------------------
SIZES="100 250 500 1000"
RUNS=3
QUICK=0
SKIP_GEN=0
DATA_DIR=""
RESULTS_DIR="results"
GENERATOR="../Sup_files/generate_transactions"

usage() {
    cat <<'EOF'
Usage: run_tests.sh [options]

  --sizes "100 250 500 1000"  target dataset sizes in MB
  --runs N                    timed repetitions per size (best is reported)
  --data-dir DIR              dataset storage (default: C:/Users/<you>/nosql_pipeline_bench,
                              deliberately outside the OneDrive-synced project)
  --results-dir DIR           result files (default: ./results)
  --generator FILE            override generator path
  --skip-gen                  reuse existing datasets, skip generation
  --quick                     fast smoke test: sizes "5 10", 1 timed run
  --clean                     delete the data dir (benchmark datasets) and exit
EOF
    exit 0
}
die() { printf 'run_tests.sh: ERROR: %s\n' "$*" >&2; exit 1; }

# Default generator path: the course layout (../Sup_files); if that does not
# exist (e.g. a fresh clone of the repo), fall back to a generator shipped
# next to this script.  --generator still overrides both.
if [ ! -f "$GENERATOR" ] && [ -f "generate_transactions" ]; then
    GENERATOR="generate_transactions"
fi

# ---- argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
    case $1 in
        --sizes)       [ $# -ge 2 ] || die "--sizes needs a value"
                       SIZES=$2; shift 2 ;;
        --runs)        [ $# -ge 2 ] || die "--runs needs a value"
                       RUNS=$2; shift 2 ;;
        --data-dir)    [ $# -ge 2 ] || die "--data-dir needs a value"
                       DATA_DIR=$2; shift 2 ;;
        --results-dir) [ $# -ge 2 ] || die "--results-dir needs a value"
                       RESULTS_DIR=$2; shift 2 ;;
        --generator)   [ $# -ge 2 ] || die "--generator needs a value"
                       GENERATOR=$2; shift 2 ;;
        --skip-gen)    SKIP_GEN=1; shift ;;
        --quick)       QUICK=1; SIZES="5 10"; RUNS=1; shift ;;
        --clean)       CLEAN=1; shift ;;
        -h|--help)     usage ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

for s in $SIZES; do
    case $s in ''|*[!0-9]*) die "--sizes must be integers (MB): got '$s'" ;; esac
done
case $RUNS in ''|*[!0-9]*) die "--runs must be an integer" ;; esac
[ "$RUNS" -ge 1 ] || die "--runs must be >= 1"

# Data dir default: outside the OneDrive-synced project tree.  USERPROFILE is
# a Windows path (backslashes); convert to C:/... form which BOTH MSYS tools
# and Windows-native tools (python3, stat, cat, ...) understand.
if [ -z "$DATA_DIR" ]; then
    if [ -n "${USERPROFILE:-}" ]; then
        DATA_DIR="${USERPROFILE//\\//}/nosql_pipeline_bench"
    else
        DATA_DIR="$HOME/nosql_pipeline_bench"
    fi
fi

case "$DATA_DIR" in
    *[Oo]ne[Dd]rive*)
        printf 'run_tests.sh: WARNING: data dir is inside OneDrive (%s)\n' "$DATA_DIR" >&2
        printf '             1.85 GB of benchmark data will sync and skew timings.\n' >&2
        ;;
esac

# --clean: remove the data dir (only generated benchmark data lives there)
if [ "${CLEAN:-0}" = 1 ]; then
    printf 'run_tests.sh: removing %s\n' "$DATA_DIR"
    rm -rf "$DATA_DIR"
    printf 'done.\n'
    exit 0
fi

mkdir -p "$DATA_DIR" "$RESULTS_DIR"

# If EPOCHREALTIME was exported by a parent shell it becomes a frozen copy;
# unset it so bash re-creates it as a live (dynamic) microsecond clock.
unset EPOCHREALTIME 2> /dev/null || true

hr() { printf '%s\n' "----------------------------------------------------------------"; }
# (On Linux/WSL "./pipeline.sh" just works; on some Windows Git Bash setups
# shebang scripts cannot be exec'd directly, so fall back to "bash ...".)
if [ -x ./pipeline.sh ] && ./pipeline.sh --help > /dev/null 2>&1; then
    PIPE=(./pipeline.sh)
else
    PIPE=(bash ./pipeline.sh)
fi

if "$GENERATOR" --records 1 --seed 0 > /dev/null 2>&1; then
    GEN=("$GENERATOR")
elif python3 "$GENERATOR" --records 1 --seed 0 > /dev/null 2>&1; then
    GEN=(python3 "$GENERATOR")
else
    die "cannot execute the generator: $GENERATOR"
fi

# ---- helpers -----------------------------------------------------------------
now_s() {                       # current time in seconds (sub-ms precision)
    printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}"
}

# timed_run CMD...  -> runs CMD, stores wall seconds in TIMED_RESULT.
# The caller's stdout redirection applies to CMD only; TIMED_RESULT is a
# shell variable, so it is never swallowed by a redirect.
timed_run() {
    local t0 t1
    t0=$(now_s)
    PIPELINE_QUIET=1 "$@"       # harmless for non-pipeline commands
    t1=$(now_s)
    TIMED_RESULT=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')
}

filesize() {                    # bytes, portable
    stat -c %s "$1" 2> /dev/null || wc -c < "$1"
}

KNOWN_ANSWER_FAILS=0
KNOWN_RESULTS=""
check() {   # check LABEL EXPECTED ACTUAL  (prints verdict, accumulates for report)
    if [ "$2" = "$3" ]; then
        printf 'known-answer check (%s): PASS\n' "$1"
        KNOWN_RESULTS="${KNOWN_RESULTS}known-answer check (${1}): PASS"$'\n'
    else
        printf 'known-answer check (%s): FAIL\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"
        KNOWN_RESULTS="${KNOWN_RESULTS}known-answer check (${1}): FAIL"$'\n'
        KNOWN_ANSWER_FAILS=$((KNOWN_ANSWER_FAILS + 1))
    fi
}

# ============================================================================
# SECTION A - functional demonstration
# All test data follows the problem-statement schema (transaction_id, date,
# category, quantity, price) and comes from generate_transactions, plus one
# small hand-crafted known-answer file that exercises every malformed-row
# rule and the WHERE/HAVING boundary cases.
# ============================================================================
echo
hr; echo "SECTION A - functional demonstration"; hr

# ---- A1: known-answer test ---------------------------------------------------
# 25 hand-crafted rows; 14 violate a rule (all 6 reject reasons represented);
# valid rows cover: date boundary 2026-01-01 (in) / 2025-12-31 (out) /
# 2024-02-29 (valid leap day, out by cutoff), quantity boundary 3 (in) /
# 2 (out), revenue boundary 100000.00 (out) / 100000.004 (in), and an
# empty-category row (valid; groups under "").
KA="$RESULTS_DIR/ka_input.tsv"
cat > "$KA" <<'KA_EOF'
transaction_id	date	category	quantity	price
T000000000001	2026-01-01	Jewelry	3	33333.50
T000000000002	2026-01-01	Books	4	25000
T000000000003	2026-01-02	Jewelry	5	20000.0008
T000000000004	2025-12-31	Books	9	9999
T000000000005	2026-01-01	Books	3	10
T000000000006	2024-02-29	Garden	3	100
T000000000007	2023-02-29	Garden	3	100
T000000000008	2026-13-01	Garden	3	100
T000000000009	2026-04-31	Garden	3	100
T000000000010	2026-4-05	Garden	3	100
T000000000011	2026-01-05	Garden	-3	100
T000000000012	2026-01-05	Garden	3.0	100
T000000000013	2026-01-05	Garden	 3	100
T000000000014	2026-01-05	Garden	3	10.
T000000000015	2026-01-05	Garden	3	1e3
T000000000016	2026-01-05	Garden	3	-5
T000000000017	2026-01-05	Garden	3	
T000000000018	2026-01-05	Garden	3
T000000000019	2026-01-05	Garden	3	100	EXTRA

T000000000020	2026-01-05	Books	2	50000
T000000000021	2026-01-05	Books	3	50000
T000000000022	2026-01-05		3	100
T000000000023	2026-01-05	Outdoor	3	999999.99
T000000000024	2026-01-05	Office	3	33333.34
KA_EOF

echo "A1: known-answer test on results/ka_input.tsv (25 rows, 14 malformed)"
"${PIPE[@]}" "$KA" "$RESULTS_DIR/ka_input.rejects.log" > "$RESULTS_DIR/ka_output.txt"
echo "pipeline output:"
cat "$RESULTS_DIR/ka_output.txt"

actual=$(cat "$RESULTS_DIR/ka_output.txt")
expected=$(printf 'category\ttransactions\trevenue\nOutdoor\t1\t2999999.97\nBooks\t3\t250030.00\nJewelry\t2\t200000.50\nOffice\t1\t100000.02')
check "ka output table" "$expected" "$actual"
actual=$(awk -F'\t' '$1 == "rejected_total" { print $2 }' "$RESULTS_DIR/ka_input.rejects.log")
check "ka rejected count" "14" "$actual"
actual=$(awk -F'\t' '$1 == "where_filtered" { print $2 }' "$RESULTS_DIR/ka_input.rejects.log")
check "ka rows filtered by WHERE" "3" "$actual"
actual=$(awk -F'\t' '$1 == "passed_where" { print $2 }' "$RESULTS_DIR/ka_input.rejects.log")
check "ka rows passing WHERE" "8" "$actual"

# ---- A2: 100000 generated records (valid data) --------------------------------
echo "A2: generating 100000 records with generate_transactions (valid data) ..."
V="$DATA_DIR/demo_valid_100k.tsv"
timed_run "${GEN[@]}" --records 100000 --seed 42 > "$V"
printf 'generated %s bytes in %ss\n' "$(filesize "$V")" "$TIMED_RESULT"
echo "first 3 lines of the generated file:"
head -n 3 "$V"
echo "pipeline output (all 20 categories clear HAVING; LIMIT keeps top 10):"
"${PIPE[@]}" "$V" "$V.rej.log" > "$RESULTS_DIR/demo_valid_100k.out"
cat "$RESULTS_DIR/demo_valid_100k.out"

# ---- A3: 100000 generated records with ~1% malformed rows ---------------------
echo
echo "A3: generating 100000 records with --malformed (~1% bad rows) ..."
M="$DATA_DIR/demo_malformed_100k.tsv"
timed_run "${GEN[@]}" --records 100000 --seed 42 --malformed > "$M"
printf 'generated %s bytes in %ss\n' "$(filesize "$M")" "$TIMED_RESULT"
echo "pipeline output (malformed rows are skipped, never fatal):"
"${PIPE[@]}" "$M" "$M.rej.log" > "$RESULTS_DIR/demo_malformed_100k.out"
cat "$RESULTS_DIR/demo_malformed_100k.out"
echo
echo "reject log summary:"
awk '/^# ---- summary ----$/ { p = 1 } p' "$M.rej.log"
echo
echo "first 3 rejected rows as logged (line_no / reason / raw row):"
awk -F'\t' '/^[0-9]+\t/ { print; if (++n == 3) exit }' "$M.rej.log"

# ---- report file ---------------------------------------------------------------
{
    echo "=== A1: known-answer input (25 rows; results/ka_input.tsv) ==="
    cat "$KA"
    echo
    echo "=== A1: pipeline output ==="
    cat "$RESULTS_DIR/ka_output.txt"
    echo
    echo "=== A1: reject log ==="
    cat "$RESULTS_DIR/ka_input.rejects.log"
    echo
    echo "=== A1: known-answer check results ==="
    printf '%s' "$KNOWN_RESULTS"
    echo
    echo "=== A2: first 3 lines of the generated valid file ==="
    head -n 3 "$V"
    echo
    echo "=== A2: pipeline output ==="
    cat "$RESULTS_DIR/demo_valid_100k.out"
    echo
    echo "=== A3: first 3 lines of the generated malformed file ==="
    head -n 3 "$M"
    echo
    echo "=== A3: pipeline output ==="
    cat "$RESULTS_DIR/demo_malformed_100k.out"
    echo
    echo "=== A3: reject log summary ==="
    awk '/^# ---- summary ----$/ { p = 1 } p' "$M.rej.log"
    echo
    echo "=== A3: first 3 rejected rows ==="
    awk -F'\t' '/^[0-9]+\t/ { print; if (++n == 3) exit }' "$M.rej.log"
} | tee "$RESULTS_DIR/functional_demo.txt"

# ============================================================================
# SECTION B - generate datasets at the target sizes
# ============================================================================
echo
hr; echo "SECTION B - dataset generation (target sizes: $SIZES MB)"; hr

SIZES_SORTED=$(printf '%s\n' $SIZES | sort -n)

SIZE_MB=(); SIZE_BYTES=(); SIZE_RECS=()

if [ "$SKIP_GEN" -ne 1 ]; then
    # One-off probe: measure the generator's average bytes/row (20K rows).
    PROBE_RECS=20000
    echo "measuring average row size with a $PROBE_RECS-record probe ..."
    "${GEN[@]}" --records "$PROBE_RECS" --seed 42 > "$DATA_DIR/.probe.tsv"
    PROBE_BYTES=$(filesize "$DATA_DIR/.probe.tsv")
    BPR=$(( (PROBE_BYTES - 100) / PROBE_RECS ))   # minus ~header length
    rm -f "$DATA_DIR/.probe.tsv"
    printf 'average row size: %s bytes  =>  ~%s records per 100 MB\n\n' "$BPR" "$((100000000 / BPR))"
fi

for MB in $SIZES_SORTED; do
    TARGET=$((MB * 1000000))                       # decimal MB
    F="$DATA_DIR/transactions_${MB}MB.tsv"
    META="$DATA_DIR/transactions_${MB}MB.meta"

    if [ "$SKIP_GEN" -eq 1 ]; then
        [ -f "$F" ] || die "--skip-gen: missing dataset $F (run without --skip-gen first)"
        ACTUAL=$(filesize "$F")
        RECORDS=$(awk -F= '$1 == "records" { print $2 }' "$META" 2> /dev/null || printf '?')
        printf 'reusing existing %s (%s bytes)\n' "$F" "$ACTUAL"
    else
        N=$((TARGET / BPR))
        for ATTEMPT in 1 2; do
            printf 'generating transactions_%sMB.tsv: ~%s records (attempt %s) ...\n' "$MB" "$N" "$ATTEMPT"
            timed_run "${GEN[@]}" --records "$N" --seed 42 > "$F"
            ACTUAL=$(filesize "$F")
            PCT=$(awk -v a="$ACTUAL" -v t="$TARGET" 'BEGIN { printf "%+.1f", (a - t) * 100 / t }')
            printf '  -> %s bytes (%s%% vs %s MB target), took %ss\n' "$ACTUAL" "$PCT" "$MB" "$TIMED_RESULT"
            # accept if within +/-2% of target
            if awk -v a="$ACTUAL" -v t="$TARGET" 'BEGIN { d = a - t; if (d < 0) d = -d; exit (d / t <= 0.02) ? 0 : 1 }'; then
                break
            fi
            if [ "$ATTEMPT" -eq 2 ]; then break; fi
            N=$(awk -v n="$N" -v t="$TARGET" -v a="$ACTUAL" 'BEGIN { printf "%d", n * t / a }')
        done
        RECORDS=$N
        printf 'records=%s\nbytes=%s\n' "$RECORDS" "$ACTUAL" > "$META"
    fi

    SIZE_MB+=("$MB"); SIZE_BYTES+=("$ACTUAL"); SIZE_RECS+=("$RECORDS")
done

# ============================================================================
# SECTION C - timing benchmark
# ============================================================================
echo
hr; echo "SECTION C - timing benchmark (best of $RUNS run(s) per size)"; hr

{
    echo
    echo "--- C1: environment ---"
    printf 'date        : %s\n' "$(date)"
    printf 'os          : %s\n' "$(uname -sr)"
    printf 'cpu threads : %s\n' "$(nproc 2> /dev/null || printf 'n/a')"
    printf 'bash        : %s\n' "${BASH_VERSION:-unknown}"
    printf 'awk         : %s\n' "$(awk -W version 2>&1 | awk 'NR == 1')"
    printf 'sort        : %s\n' "$(sort --version 2>&1 | awk 'NR == 1')"
    printf 'python      : %s\n' "$(python3 --version 2>&1)"
    printf 'timing      : wall clock via $EPOCHREALTIME, best of %s run(s)\n' "$RUNS"

    echo
    echo "--- C2: full-pipeline timing per dataset ---"
    printf '%-10s %-12s %-24s %-9s %-12s\n' "Size(MB)" "Records" "Runs(s)" "Best(s)" "MB/s"
    BEST_TIMES=()
    for i in "${!SIZE_MB[@]}"; do
        MB=${SIZE_MB[$i]}; BYTES=${SIZE_BYTES[$i]}; RECS=${SIZE_RECS[$i]}
        F="$DATA_DIR/transactions_${MB}MB.tsv"
        TIMES=()
        for _ in $(seq 1 "$RUNS"); do
            timed_run "${PIPE[@]}" "$F" "$F.rej.log" > /dev/null
            TIMES+=("$TIMED_RESULT")
        done
        BEST=$(printf '%s\n' "${TIMES[@]}" | awk 'NR == 1 || $0 + 0 < min { min = $0 + 0 } END { printf "%.3f", min }')
        BEST_TIMES+=("$BEST")
        MBPS=$(awk -v b="$BYTES" -v t="$BEST" 'BEGIN { printf "%.1f", b / 1000000 / t }')
        RUNS_CELL=$(printf '%s / ' "${TIMES[@]}"); RUNS_CELL=${RUNS_CELL%/ }
        printf '%-10s %-12s %-24s %-9s %-12s\n' "$MB" "$RECS" "$RUNS_CELL" "$BEST" "$MBPS"
    done

    echo
    echo "--- C3: where does the time go? (largest dataset, 1 run each) ---"
    echo "    (pipeline.sh -n N runs only the first N stages; see README)"
    BIGGEST=${SIZE_MB[$(( ${#SIZE_MB[@]} - 1 ))]}
    F="$DATA_DIR/transactions_${BIGGEST}MB.tsv"
    printf '%-52s %10s\n' "configuration" "time(s)"
    timed_run cat "$F" > /dev/null
    printf '%-52s %10s\n' "cat FILE > /dev/null  (raw read baseline)" "$TIMED_RESULT"
    for STAGES in 1 2 3 6; do
        timed_run "${PIPE[@]}" -n "$STAGES" "$F" "$DATA_DIR/.stage_rej.log" > /dev/null
        case $STAGES in
            1) DESC="stage 1 only: validation + WHERE + projection" ;;
            2) DESC="stages 1-2: ... + GROUP BY / aggregation" ;;
            3) DESC="stages 1-3: ... + HAVING" ;;
            6) DESC="full pipeline: ... + sort + LIMIT + formatting" ;;
        esac
        printf '%-52s %10s\n' "$DESC" "$TIMED_RESULT"
    done

    echo
    echo "--- C4: one run of the largest dataset under the classic 'time' ---"
    { time PIPELINE_QUIET=1 "${PIPE[@]}" "$F" "$DATA_DIR/.stage_rej.log" > /dev/null; } 2>&1 | awk '/^(real|user|sys)/'

    echo
    echo "--- C5: results table (input size vs execution time) ---"
    printf '%-10s %-12s %-10s %-12s\n' "Size(MB)" "Records" "Best(s)" "MB/s"
    for i in "${!SIZE_MB[@]}"; do
        MBPS=$(awk -v b="${SIZE_BYTES[$i]}" -v t="${BEST_TIMES[$i]}" 'BEGIN { printf "%.1f", b / 1000000 / t }')
        printf '%-10s %-12s %-10s %-12s\n' "${SIZE_MB[$i]}" "${SIZE_RECS[$i]}" "${BEST_TIMES[$i]}" "$MBPS"
    done
} | tee "$RESULTS_DIR/benchmark_results.txt"

echo
printf 'datasets kept in : %s\n' "$DATA_DIR"
printf 'results written  : %s/functional_demo.txt, %s/benchmark_results.txt (+ reject logs)\n' "$RESULTS_DIR" "$RESULTS_DIR"
printf 'to free the disk: ./run_tests.sh --clean  (deletes %s)\n' "$DATA_DIR"

if [ "$KNOWN_ANSWER_FAILS" -gt 0 ]; then
    printf 'run_tests.sh: %s known-answer check(s) FAILED\n' "$KNOWN_ANSWER_FAILS" >&2
    exit 1
fi
