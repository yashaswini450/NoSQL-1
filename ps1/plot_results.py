#!/usr/bin/env python3
"""Aggregates raw per-run timings from run_benchmark.py into summary stats and
produces the plots used in the scaling analysis writeup.
"""
import argparse
import os

import matplotlib.pyplot as plt
import pandas as pd


def load_raw(results_file):
    df = pd.read_csv(results_file)
    df["query_num"] = df["query"].str.replace("Q", "", regex=False).astype(int)
    return df


def summarize(df):
    summary = (
        df.groupby(["scale_factor", "query", "query_num"])["time_seconds"]
        .agg(["mean", "median", "std", "min", "max", "count"])
        .reset_index()
        .sort_values(["scale_factor", "query_num"])
    )
    return summary


def plot_total_time_vs_scale(summary, out_dir):
    totals = summary.groupby("scale_factor")["mean"].sum().reset_index()
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.plot(totals["scale_factor"], totals["mean"], marker="o")
    ax.set_xlabel("Scale Factor")
    ax.set_ylabel("Total execution time (s), sum of Q1-Q22 means")
    ax.set_title("Total TPC-H Execution Time vs Scale Factor")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.grid(True, which="both", linestyle="--", alpha=0.5)
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "total_time_vs_scale.png"), dpi=150)
    plt.close(fig)
    return totals


def plot_per_query_grid(summary, out_dir):
    queries = sorted(summary["query_num"].unique())
    ncols = 5
    nrows = -(-len(queries) // ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(3 * ncols, 2.5 * nrows), sharex=True)
    axes = axes.flatten()

    for ax, qnum in zip(axes, queries):
        qdata = summary[summary["query_num"] == qnum].sort_values("scale_factor")
        ax.plot(qdata["scale_factor"], qdata["mean"], marker="o", markersize=3)
        ax.set_title(f"Q{qnum}", fontsize=9)
        ax.set_xscale("log", base=2)
        ax.set_yscale("log")
        ax.grid(True, which="both", linestyle="--", alpha=0.4)

    for ax in axes[len(queries):]:
        ax.axis("off")

    fig.suptitle("Per-Query Execution Time vs Scale Factor (log-log)")
    fig.supxlabel("Scale Factor")
    fig.supylabel("Mean time (s)")
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "per_query_vs_scale.png"), dpi=150)
    plt.close(fig)


def plot_scaling_efficiency(summary, out_dir):
    baseline_sf = summary["scale_factor"].min()
    pivot = summary.pivot(index="query_num", columns="scale_factor", values="mean")
    normalized = pivot.div(pivot[baseline_sf], axis=0)

    fig, ax = plt.subplots(figsize=(7, 5))
    for qnum in normalized.index:
        ax.plot(normalized.columns, normalized.loc[qnum], alpha=0.4, linewidth=1, color="steelblue")

    ideal_x = sorted(normalized.columns)
    ideal_y = [x / baseline_sf for x in ideal_x]
    ax.plot(ideal_x, ideal_y, linestyle="--", color="red", label="Ideal linear scaling")

    ax.set_xlabel("Scale Factor")
    ax.set_ylabel(f"Time relative to SF={baseline_sf}")
    ax.set_title("Per-Query Scaling Relative to Baseline vs Ideal Linear Scaling")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.legend()
    ax.grid(True, which="both", linestyle="--", alpha=0.5)
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "scaling_efficiency.png"), dpi=150)
    plt.close(fig)


def parse_args():
    parser = argparse.ArgumentParser(description="Plot TPC-H scaling benchmark results.")
    parser.add_argument(
        "--input",
        default=os.path.join(os.path.dirname(__file__), "scaling_results.csv"),
        help="Raw results CSV produced by run_benchmark.py.",
    )
    parser.add_argument(
        "--out-dir",
        default=os.path.join(os.path.dirname(__file__), "plots"),
        help="Directory to write plots and summary CSV into.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    raw = load_raw(args.input)
    summary = summarize(raw)
    summary.to_csv(os.path.join(args.out_dir, "summary_stats.csv"), index=False)

    totals = plot_total_time_vs_scale(summary, args.out_dir)
    plot_per_query_grid(summary, args.out_dir)
    plot_scaling_efficiency(summary, args.out_dir)

    print("Wrote summary_stats.csv and 3 plots to", args.out_dir)
    print(totals.to_string(index=False))
