import psycopg2
import time
import csv
import os
import re

# Configuration
DB_NAME = "tpch_sf1"
USER = os.environ.get("USER") 
QUERIES_DIR = "tpch-kit/dbgen"
SCALE_FACTOR = 1
RESULTS_FILE = "scaling_results.csv"

def clean_query(sql):
    """Formats TPC-H generated SQL to be PostgreSQL-compatible."""
    # Fix interval syntax (e.g., 'day (3)' -> 'day')
    sql = sql.replace("day (3)", "day")
    
    # Remove unsupported 'limit -1' entirely
    sql = re.sub(r"limit\s+-1;?", "", sql, flags=re.IGNORECASE)
    
    # Remove dangling semicolons before valid limit clauses
    sql = re.sub(r";\s*limit", "\nlimit", sql, flags=re.IGNORECASE)
    
    return sql

def run_benchmark():
    conn = psycopg2.connect(dbname=DB_NAME, user=USER)
    conn.autocommit = True
    cursor = conn.cursor()

    results = []
    total_time = 0

    print(f"Starting TPC-H Benchmark for Scale Factor {SCALE_FACTOR}...")

    for i in range(1, 23):
        query_file = os.path.join(QUERIES_DIR, f"q{i}.sql")
        
        if not os.path.exists(query_file):
            print(f"Skipping Q{i} (File not found)")
            continue

        with open(query_file, 'r') as f:
            sql = clean_query(f.read())

        try:
            start_time = time.time()
            cursor.execute(sql)
            
            # Fetch results to ensure execution completes
            if cursor.description:
                cursor.fetchall()
                
            end_time = time.time()
            
            exec_time = end_time - start_time
            total_time += exec_time
            print(f"Query {i}: {exec_time:.4f} seconds")
            
            results.append({
                "scale_factor": SCALE_FACTOR,
                "query": f"Q{i}",
                "time_seconds": exec_time
            })
            
        except Exception as e:
            print(f"Query {i} failed: {e}")
            # Rollback in case of error so subsequent queries can run
            conn.rollback()

    print(f"\nTotal Execution Time: {total_time:.4f} seconds")

    # Append to CSV for the scaling study requirement
    file_exists = os.path.isfile(RESULTS_FILE)
    with open(RESULTS_FILE, 'a', newline='') as csvfile:
        fieldnames = ['scale_factor', 'query', 'time_seconds']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        
        if not file_exists:
            writer.writeheader()
        writer.writerows(results)

    cursor.close()
    conn.close()

if __name__ == "__main__":
    run_benchmark()