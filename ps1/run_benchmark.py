#!/usr/bin/env python3
"""Runs the TPC-H query set against each scale-factor database and records
per-query execution times for the scaling study. Produces a long-format CSV
(one row per run) that plot_results.py consumes.
"""
import argparse
import csv
import os
import re
import time

import psycopg2

QUERIES_DIR = os.path.join(os.path.dirname(__file__), "tpch-kit", "dbgen")


def clean_query(sql):
    """Formats TPC-H generated SQL to be PostgreSQL-compatible."""
    # Fix interval syntax (e.g., 'day (3)' -> 'day')
    sql = sql.replace("day (3)", "day")

    # Remove unsupported 'limit -1' entirely
    sql = re.sub(r"limit\s+-1;?", "", sql, flags=re.IGNORECASE)

    # Remove dangling semicolons before valid limit clauses
    sql = re.sub(r";\s*limit", "\nlimit", sql, flags=re.IGNORECASE)

    return sql


def run_query_file(cursor, query_file):
    with open(query_file, "r") as f:
        sql = clean_query(f.read())

    start_time = time.perf_counter()
    cursor.execute(sql)
    if cursor.description:
        cursor.fetchall()
    return time.perf_counter() - start_time


def run_benchmark(scale_factors, repeats, user, results_file):
    file_exists = os.path.isfile(results_file)
    with open(results_file, "a", newline="") as csvfile:
        fieldnames = ["scale_factor", "query", "run", "time_seconds"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        if not file_exists:
            writer.writeheader()

        for sf in scale_factors:
            db_name = f"tpch_sf{sf}"
            print(f"\n=== Scale Factor {sf} ({db_name}) ===")

            conn = psycopg2.connect(dbname=db_name, user=user)
            conn.autocommit = True
            cursor = conn.cursor()

            for i in range(1, 23):
                query_file = os.path.join(QUERIES_DIR, f"q{i}.sql")
                if not os.path.exists(query_file):
                    print(f"Skipping Q{i} (file not found)")
                    continue

                for run in range(1, repeats + 1):
                    try:
                        exec_time = run_query_file(cursor, query_file)
                        print(f"SF{sf} Q{i} run {run}: {exec_time:.4f}s")
                        writer.writerow(
                            {
                                "scale_factor": sf,
                                "query": f"Q{i}",
                                "run": run,
                                "time_seconds": f"{exec_time:.6f}",
                            }
                        )
                        csvfile.flush()
                    except Exception as e:
                        print(f"SF{sf} Q{i} run {run} failed: {e}")
                        conn.rollback()

            cursor.close()
            conn.close()

    print(f"\nRaw results written to {results_file}")


def parse_args():
    parser = argparse.ArgumentParser(description="Run TPC-H benchmark across scale factors.")
    parser.add_argument(
        "--scale-factors",
        type=int,
        nargs="+",
        default=[1, 2, 4, 8],
        help="Scale factors to benchmark (each must have a tpch_sf<N> database already loaded).",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=3,
        help="Number of times to run each query per scale factor (reduces timing noise).",
    )
    parser.add_argument(
        "--user",
        default=os.environ.get("PGUSER") or os.environ.get("USER"),
        help="PostgreSQL user (defaults to $PGUSER or $USER).",
    )
    parser.add_argument(
        "--output",
        default=os.path.join(os.path.dirname(__file__), "scaling_results.csv"),
        help="Path to append raw results to.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    run_benchmark(args.scale_factors, args.repeats, args.user, args.output)
