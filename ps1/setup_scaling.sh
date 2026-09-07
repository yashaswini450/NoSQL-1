#!/bin/bash
cd tpch-kit/dbgen

for SF in 2 4 8; do
    DB_NAME="tpch_sf${SF}"
    echo "========================================"
    echo "Starting setup for Scale Factor $SF ($DB_NAME)"
    echo "========================================"
    
    # Create the database and apply the schema
    createdb $DB_NAME
    psql -d $DB_NAME -f dss.ddl
    
    # Generate the data (force overwrite)
    ./dbgen -vf -s $SF
    
    # Clean the trailing pipes
    for i in *.tbl; do sed -i '' 's/|$//' $i; done
    
    # Load the data into the new database
    psql -d $DB_NAME -f load_data.sql
done
