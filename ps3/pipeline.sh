#!/usr/bin/env bash
#
# ============================================================================
# pipeline.sh - streaming Unix implementation of the Part-3 SQL query
# ============================================================================
#
# USAGE
#     ./pipeline.sh INPUT.tsv [REJECT_LOG]
#     ./pipeline.sh -n STAGES INPUT.tsv [REJECT_LOG]
#
#     INPUT.tsv    tab-separated transactions file WITH a header row.
#     REJECT_LOG   malformed-row log: one line per rejected row + summary
#                  (default: "<INPUT.tsv>.rejects.log").
#     -n STAGES    run only the first N stages, 1..6 (default 6 = the whole
#                  query).  Used by run_tests.sh to measure the cost of each
#                  stage separately:
#                    1 = validate + WHERE + projection
#                    2 = ... + GROUP BY / COUNT / SUM
#                    3 = ... + HAVING
#                    4 = ... + ORDER BY
#                    5 = ... + LIMIT
#                    6 = ... + final SELECT formatting (default)
#
# THE QUERY IMPLEMENTED (logical specification only - no database is used)
#
#     SELECT   category, COUNT(*) AS transactions,
#              SUM(quantity * price) AS revenue
#     FROM     transactions
#     WHERE    date >= '2026-01-01' AND quantity > 2
#     GROUP BY category
#     HAVING   SUM(quantity * price) > 100000
#     ORDER BY revenue DESC
#     LIMIT    10;
#
# PIPELINE: one Unix stage per SQL clause (details in README.md)
#
#     s1  awk    row validation (malformed rows -> reject log), WHERE filter,
#                projection to "category <TAB> quantity*price"
#     s2  awk    GROUP BY + COUNT(*) + SUM()   (associative arrays)
#     s3  awk    HAVING  (revenue > cutoff)
#     s4  sort   ORDER BY revenue DESC
#     s5  head   LIMIT 10
#     s6  awk    SELECT list: column header + final formatting
#
# STREAMING / MEMORY GUARANTEE
#     The input is consumed line-by-line through pipes; at no point is the
#     file loaded into memory.  Peak memory is O(#distinct categories):
#     stage 2 holds one counter and one accumulator per category, and sort
#     only ever sees one line per category.  Verified on 1 GB inputs.
#
# SCHEMA HANDLING
#     Expected input (problem statement / generate_transactions), TAB-
#     separated with a header row:
#       transaction_id  date  category  quantity  price
#     Column POSITIONS are nevertheless resolved from the header row rather
#     than hardcoded, so a file whose columns arrive in a different order
#     still processes correctly; a header missing any of category,
#     quantity, price, date is a hard error before any data is processed.
#
# MALFORMED-ROW POLICY (never fatal - each bad row is logged and skipped)
#     empty_line      blank line
#     missing_field   fewer fields than the header
#     extra_field     more fields than the header
#     bad_quantity    quantity is not an unsigned integer (e.g. "bad", "-3")
#     bad_price       price is not a plain decimal number (e.g. "", "N/A")
#     bad_date        date is not a real calendar date in YYYY-MM-DD form
#                     (regex + month/day range check, leap years included)
#     A row is rejected for the FIRST rule it violates, so the reason counts
#     are mutually exclusive.  Rejected rows contribute to no count or sum.
# ============================================================================

set -eu
# NOTE: deliberately NOT using `set -o pipefail`: `sort | head` can close the
# pipe early (head exits after 10 lines) and make sort die of SIGPIPE with a
# non-zero status even though the output is correct.  Realistic failures are
# caught by the fail-fast checks below instead.

# Make collation and regexes byte-oriented: deterministic tie-breaks in sort
# and noticeably faster sorting/regex on large inputs.
export LC_ALL=C

# ---- tunables: the literals of the SQL query (env-overridable) ------------
DATE_CUTOFF="${DATE_CUTOFF:-2026-01-01}"   # WHERE  date >= (ISO-8601 dates
QTY_CUTOFF="${QTY_CUTOFF:-2}"              # WHERE  quantity >   compare cor-
REV_CUTOFF="${REV_CUTOFF:-100000}"         # HAVING revenue >   rectly as
TOP_N="${TOP_N:-10}"                       # LIMIT               plain strings)
PIPELINE_QUIET="${PIPELINE_QUIET:-0}"      # 1 = suppress stderr summary line

TAB=$'\t'
STAGES=6

usage() {
    cat <<'EOF'
Usage: pipeline.sh [-n STAGES] INPUT.tsv [REJECT_LOG]

  INPUT.tsv    input TSV file (must have a header row)
  REJECT_LOG   malformed-row log, default "<INPUT.tsv>.rejects.log"
  -n STAGES    run only the first N stages, 1..6 (default 6 = full query)

Environment overrides:
  DATE_CUTOFF (2026-01-01)   WHERE  date >=
  QTY_CUTOFF  (2)            WHERE  quantity >
  REV_CUTOFF  (100000)       HAVING revenue >
  TOP_N       (10)           LIMIT
  PIPELINE_QUIET=1           suppress the one-line stderr summary
EOF
}

die() { printf 'pipeline.sh: ERROR: %s\n' "$*" >&2; exit 1; }

# ---- argument parsing ------------------------------------------------------
while [ $# -gt 0 ]; do
    case $1 in
        -n)  [ $# -ge 2 ] || die "-n requires a value (1..6)"
             STAGES=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --)  shift; break ;;
        -*)  die "unknown option: $1 (try --help)" ;;
        *)   break ;;
    esac
done
[ $# -ge 1 ] && [ $# -le 2 ] || { usage >&2; die "expected INPUT.tsv [REJECT_LOG]"; }
[ "$STAGES" -ge 1 ] && [ "$STAGES" -le 6 ] || die "-n STAGES must be an integer 1..6"

INPUT=$1
REJECT_LOG=${2:-${INPUT}.rejects.log}

# ---- fail-fast checks ------------------------------------------------------
[ -f "$INPUT" ] || die "input file not found: $INPUT"

# Read only the first line (the header) - bash builtin, no subprocess.
IFS= read -r header < "$INPUT" || die "input is empty (no header row): $INPUT"
header=${header#$'\xEF\xBB\xBF'}   # strip a UTF-8 BOM if present
header=${header%$'\r'}             # tolerate CRLF files

# ---- schema resolution: header -> column positions ------------------------
# (The DB analogue: looking up column ordinals in the table's catalog.)
schema=$(printf '%s\n' "$header" | awk -F'\t' '
    {
        for (i = 1; i <= NF; i++) col[tolower($i)] = i   # name -> position
        if (!("category" in col && "quantity" in col &&
              "price" in col && "date" in col)) {
            printf "pipeline.sh: ERROR: header must contain the columns " \
                   "category, quantity, price, date\n" \
                   "pipeline.sh: ERROR: got instead: %s\n", $0 > "/dev/stderr"
            exit 2
        }
        print col["category"], col["quantity"], col["price"], col["date"], NF
    }') || die "could not resolve the schema from the header row"
read -r CI QI PI DI NC <<< "$schema"   # category/quantity/price/date index,
                                       # number of columns

# Start the reject log (also fails fast if the path is not writable).
printf '# reject log - input: %s\n# line_no\treason\trow\n' "$INPUT" > "$REJECT_LOG" \
    || die "cannot write reject log: $REJECT_LOG"

# ============================================================================
# STAGE FUNCTIONS - one function per SQL clause
# ============================================================================

# ---- s1: validation (malformed-row handling) + WHERE + projection ----------
s1_validate_filter() {
    awk -F'\t' \
        -v ci="$CI" -v qi="$QI" -v pi="$PI" -v di="$DI" -v ncols="$NC" \
        -v date_min="$DATE_CUTOFF" -v qty_min="$QTY_CUTOFF" \
        -v rejlog="$REJECT_LOG" -v quiet="$PIPELINE_QUIET" '
        # ---- helpers ------------------------------------------------------
        # Strict YYYY-MM-DD and a real calendar date (month 1..12, day
        # valid for the month, February incl. leap years).
        # Note: the ERE deliberately avoids {4}/{2} interval repetition so
        # it also runs under mawk/busybox awk, not just gawk.
        function is_valid_date(s,  y, m, d, leap, maxd) {
            if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
            y = substr(s, 1, 4) + 0
            m = substr(s, 6, 2) + 0
            d = substr(s, 9, 2) + 0
            if (m < 1 || m > 12) return 0
            if (m == 2) {
                leap = (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))
                maxd = leap ? 29 : 28
            } else if (m == 4 || m == 6 || m == 9 || m == 11) {
                maxd = 30
            } else {
                maxd = 31
            }
            return (d >= 1 && d <= maxd)
        }
        # Log one rejected row (line no + reason + raw row) and count it.
        function reject(reason) {
            rej[reason]++
            rejected++
            print NR "\t" reason "\t" $0 >> rejlog
        }
        # ---- main --------------------------------------------------------
        NR == 1 { next }              # header row: schema already resolved
        {
            # Tolerate CRLF input: if the last character is a CR, drop it.
            # (substr check first: much cheaper than a regex on every line.)
            if (substr($0, length($0)) == "\r")
                $0 = substr($0, 1, length($0) - 1)   # re-splits $1..$NF
            data_rows++

            # -- structural validation ------------------------------------
            if ($0 == "")    { reject("empty_line");  next }
            if (NF != ncols) { reject(NF < ncols ? "missing_field" : "extra_field"); next }

            q = $qi; p = $pi; d = $di

            # -- type validation ------------------------------------------
            if (q !~ /^[0-9]+$/)              { reject("bad_quantity"); next }
            if (p !~ /^[0-9]+([.][0-9]+)?$/)  { reject("bad_price");    next }
            if (!is_valid_date(d))            { reject("bad_date");     next }

            # -- WHERE date >= cutoff AND quantity > cutoff ----------------
            # ISO-8601 dates compare correctly as plain strings, so the
            # lexicographic test below IS the chronological test.
            if (d < date_min)     { filtered++; next }
            if (q + 0 <= qty_min) { filtered++; next }

            # -- projection: category + this row revenue -------------------
            # printf is essential: plain `print` would stringify the number
            # through CONVFMT="%.6g" and corrupt large values
            # (e.g. 1234567.89 -> "1.23457e+06").
            emitted++
            printf "%s\t%.4f\n", $ci, (q + 0) * (p + 0)
        }
        # ---- summary -------------------------------------------------------
        END {
            print "# ---- summary ----" >> rejlog
            printf "input_data_rows\t%d\n", data_rows >> rejlog
            printf "rejected_total\t%d\n", rejected  >> rejlog
            for (r in rej) printf "rejected_%s\t%d\n", r, rej[r] >> rejlog
            printf "where_filtered\t%d\n", filtered >> rejlog
            printf "passed_where\t%d\n",  emitted  >> rejlog
            if (!quiet)
                printf "pipeline.sh: %d data rows -> %d rejected, " \
                       "%d dropped by WHERE, %d aggregated (log: %s)\n", \
                       data_rows, rejected, filtered, emitted, rejlog \
                       > "/dev/stderr"
        }'
}

# ---- s2: GROUP BY category + COUNT(*) + SUM(quantity*price) ----------------
# The associative array IS the group-by: key = category, value = running
# count / running sum.  Memory: one entry per distinct category.
s2_group_aggregate() {
    awk -F'\t' '
        { cnt[$1]++; rev[$1] += $2 }
        END {
            for (c in cnt) printf "%s\t%d\t%.4f\n", c, cnt[c], rev[c]
        }'
}

# ---- s3: HAVING SUM(quantity*price) > cutoff -------------------------------
# Input is one line per group, so a row filter on the aggregate column
# implements HAVING exactly.
s3_having() {
    awk -F'\t' -v rev_min="$REV_CUTOFF" '($3 + 0) > rev_min'
}

# ---- s4: ORDER BY revenue DESC ---------------------------------------------
# -t TAB is mandatory: category values contain spaces ("Pet Supplies") and
# with the default separator sort would split them into two fields.
# Secondary key (category ascending) only breaks exact revenue ties, which
# makes the output deterministic and reproducible.
s4_order_by() {
    sort -t "$TAB" -k3,3nr -k1,1
}

# ---- s5: LIMIT 10 -----------------------------------------------------------
s5_limit() {
    head -n "$TOP_N"
}

# ---- s6: SELECT-list projection / final formatting --------------------------
# Adds the column header and renders revenue as a money-style 2-decimal
# value.  Runs AFTER head, so the header can never be counted by LIMIT.
s6_project() {
    awk -F'\t' '
        BEGIN { print "category\ttransactions\trevenue" }
        { printf "%s\t%d\t%.2f\n", $1, $2, $3 }'
}

# ============================================================================
# COMPOSITION: choose how many stages to run (-n), wire them with pipes
# ============================================================================
case $STAGES in
    1) s1_validate_filter < "$INPUT" ;;
    2) s1_validate_filter < "$INPUT" | s2_group_aggregate ;;
    3) s1_validate_filter < "$INPUT" | s2_group_aggregate | s3_having ;;
    4) s1_validate_filter < "$INPUT" | s2_group_aggregate | s3_having | s4_order_by ;;
    5) s1_validate_filter < "$INPUT" | s2_group_aggregate | s3_having | s4_order_by | s5_limit ;;
    *) s1_validate_filter < "$INPUT" | s2_group_aggregate | s3_having \
                          | s4_order_by | s5_limit | s6_project ;;
esac
