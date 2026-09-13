#!/bin/bash
# Sets up one PostgreSQL database per TPC-H scale factor: generates data with
# dbgen, creates the schema, and bulk-loads it. Intended to run on Linux
# (Pop!_OS) where GNU sed/psql/createdb are on PATH.
set -euo pipefail

cd "$(dirname "$0")/tpch-kit/dbgen"

SCALE_FACTORS="${SCALE_FACTORS:-1 2 4 8}"

for SF in $SCALE_FACTORS; do
    DB_NAME="tpch_sf${SF}"
    echo "========================================"
    echo "Starting setup for Scale Factor $SF ($DB_NAME)"
    echo "========================================"

    # Create the database and apply the schema (idempotent: drop first if present)
    dropdb --if-exists "$DB_NAME"
    createdb "$DB_NAME"
    psql -d "$DB_NAME" -f dss.ddl

    # Generate the data (force overwrite)
    ./dbgen -vf -s "$SF"

    # Strip trailing '|' delimiters left by dbgen (GNU sed: no empty backup-suffix arg)
    for f in *.tbl; do
        sed -i 's/|$//' "$f"
    done

    # Load the data into the new database
    psql -d "$DB_NAME" -f load_data.sql

    # Free disk space before generating the next scale factor
    rm -f *.tbl
done
