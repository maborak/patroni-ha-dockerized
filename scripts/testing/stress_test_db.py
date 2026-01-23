#!/usr/bin/env python3
"""
Fast PostgreSQL stress test script using Python
Uses batch inserts, connection pooling, and parallel execution for maximum speed

To use with conda environment:
    conda activate patroni
    python3 scripts/testing/stress_test_db.py
"""

import os
import sys
import time
import random
import string
import psycopg2
from psycopg2.extras import execute_batch
from psycopg2.pool import ThreadedConnectionPool
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Tuple, Dict
import argparse

# Colors for output
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color

def generate_random_string(length: int = 32) -> str:
    """Generate a random alphanumeric string"""
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

def generate_table_name() -> str:
    """Generate a random table name: stress_table_RANDOM"""
    # Generate a random suffix (12 characters for better uniqueness)
    # Use both uppercase and lowercase letters plus digits
    suffix = ''.join(random.choices(string.ascii_letters + string.digits, k=12))
    return f"stress_table_{suffix}"

def generate_column_definitions(num_cols: int) -> List[Tuple[str, str]]:
    """Generate column definitions with random types"""
    columns = []
    type_map = {
        0: ('TEXT', 'text'),
        1: ('INTEGER', 'int'),
        2: ('BIGINT', 'bigint'),
        3: ('VARCHAR(255)', 'varchar'),
        4: ('NUMERIC(10,2)', 'numeric')
    }
    for i in range(1, num_cols + 1):
        # Use random selection instead of modulo to ensure variety
        col_type, col_suffix = type_map[random.randint(0, 4)]
        col_name = f"col_{i}_{col_suffix}"
        columns.append((col_name, col_type))
    return columns

def generate_row_values(columns: List[Tuple[str, str]]) -> Tuple:
    """Generate a single row of random values matching column types"""
    values = []
    for col_name, col_type in columns:
        if 'INTEGER' in col_type:
            values.append(random.randint(0, 1000000))
        elif 'BIGINT' in col_type:
            values.append(random.randint(0, 2**31) * random.randint(0, 2**31))
        elif 'VARCHAR' in col_type:
            values.append(generate_random_string(100))
        elif 'NUMERIC' in col_type:
            values.append(round(random.uniform(0, 10000), 2))
        elif 'TEXT' in col_type:
            values.append(generate_random_string(50))
        else:
            # Default to string if unknown type
            values.append(generate_random_string(50))
    return tuple(values)

def table_exists(conn, table_name: str) -> bool:
    """Check if a table already exists"""
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_schema = 'public' AND table_name = %s
                );
            """, (table_name,))
            return cur.fetchone()[0]
    except Exception as e:
        print(f"{Colors.YELLOW}Warning: Could not check if table exists: {e}{Colors.NC}")
        return False

def create_table(conn, table_name: str, columns: List[Tuple[str, str]]) -> bool:
    """Create a table with the specified columns"""
    try:
        with conn.cursor() as cur:
            # Check if table already exists - if so, skip creation
            cur.execute("""
                SELECT EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_schema = 'public' AND table_name = %s
                );
            """, (table_name,))
            if cur.fetchone()[0]:
                # Table already exists, skip
                return False
            
            # Build column definitions
            col_defs = ", ".join([f"{name} {type_}" for name, type_ in columns])
            
            # Create table
            cur.execute(f"""
                CREATE TABLE {table_name} (
                    id SERIAL PRIMARY KEY,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    {col_defs}
                );
            """)
            
            # Create index
            cur.execute(f"""
                CREATE INDEX IF NOT EXISTS idx_{table_name}_created 
                ON {table_name}(created_at);
            """)
            
            conn.commit()
            return True
    except Exception as e:
        print(f"{Colors.RED}ERROR: Failed to create table {table_name}: {e}{Colors.NC}")
        conn.rollback()
        return False

def insert_batch(conn, table_name: str, columns: List[Tuple[str, str]], 
                 rows: List[Tuple], batch_num: int, total_batches: int) -> int:
    """Insert a batch of rows using execute_batch for speed"""
    try:
        col_names = [name for name, _ in columns]
        placeholders = ", ".join(["%s"] * len(col_names))
        col_list = ", ".join(col_names)
        
        query = f"INSERT INTO {table_name} ({col_list}) VALUES ({placeholders})"
        
        with conn.cursor() as cur:
            execute_batch(cur, query, rows, page_size=len(rows))
            conn.commit()
            return len(rows)
    except Exception as e:
        print(f"{Colors.RED}ERROR: Failed to insert batch {batch_num}/{total_batches} into {table_name}: {e}{Colors.NC}")
        conn.rollback()
        return 0

def update_table(conn, table_name: str, update_count: int, columns: List[Tuple[str, str]]) -> bool:
    """Update random rows in a table"""
    try:
        with conn.cursor() as cur:
            # Find an integer column to update (prefer INTEGER or BIGINT)
            update_col = None
            for col_name, col_type in columns:
                if 'INTEGER' in col_type or 'BIGINT' in col_type:
                    update_col = col_name
                    break
            
            # If no integer column found, just update updated_at
            if update_col:
                cur.execute(f"""
                    UPDATE {table_name}
                    SET updated_at = CURRENT_TIMESTAMP,
                        {update_col} = {update_col} + 1
                    WHERE id IN (
                        SELECT id FROM {table_name} ORDER BY RANDOM() LIMIT %s
                    );
                """, (update_count,))
            else:
                # Just update the timestamp if no numeric column available
                cur.execute(f"""
                    UPDATE {table_name}
                    SET updated_at = CURRENT_TIMESTAMP
                    WHERE id IN (
                        SELECT id FROM {table_name} ORDER BY RANDOM() LIMIT %s
                    );
                """, (update_count,))
            conn.commit()
            return True
    except Exception as e:
        print(f"{Colors.RED}ERROR: Failed to update table {table_name}: {e}{Colors.NC}")
        conn.rollback()
        return False

def query_table(conn, table_name: str) -> int:
    """Query table and return row count"""
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT COUNT(*) FROM {table_name};")
            return cur.fetchone()[0]
    except Exception as e:
        print(f"{Colors.RED}ERROR: Failed to query table {table_name}: {e}{Colors.NC}")
        return 0

def print_progress(current: int, total: int, prefix: str = ""):
    """Print a progress bar"""
    width = 50
    percentage = int(current * 100 / total) if total > 0 else 0
    filled = int(current * width / total) if total > 0 else 0
    empty = width - filled
    
    bar = "=" * filled + " " * empty
    print(f"\r{prefix}[{bar}] {percentage:3d}% ({current}/{total})", end="", flush=True)

def load_env_file():
    """Load environment variables from .env file"""
    env_file = os.path.join(os.path.dirname(__file__), "..", ".env")
    if os.path.exists(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    os.environ[key.strip()] = value.strip()

def main():
    # Load environment variables
    load_env_file()
    
    # Parse command line arguments
    parser = argparse.ArgumentParser(description="Fast PostgreSQL stress test")
    parser.add_argument("--tables", type=int, default=int(os.getenv("NUM_TABLES", "10")),
                       help="Number of tables to create")
    parser.add_argument("--rows", type=int, default=int(os.getenv("ROWS_PER_TABLE", "1000")),
                       help="Number of rows per table")
    parser.add_argument("--cols", type=int, default=int(os.getenv("COLS_PER_TABLE", "10")),
                       help="Number of columns per table")
    parser.add_argument("--batch-size", type=int, default=int(os.getenv("BATCH_SIZE", "1000")),
                       help="Batch size for inserts")
    parser.add_argument("--threads", type=int, default=4,
                       help="Number of parallel threads")
    parser.add_argument("--host", default=os.getenv("DB_HOST_IP", "localhost"),
                       help="Database host")
    parser.add_argument("--port", type=int, default=int(os.getenv("HAPROXY_WRITE_PORT", "5551")),
                       help="Database port")
    parser.add_argument("--database", default=os.getenv("DEFAULT_DATABASE", "maborak"),
                       help="Database name")
    parser.add_argument("--user", default=os.getenv("DB_USER", "postgres"),
                       help="Database user")
    parser.add_argument("--password", default=os.getenv("POSTGRES_PASSWORD", "Dgo7cQ41WDTnd89G46TgfVtr"),
                       help="Database password")
    parser.add_argument("--debug", action="store_true",
                       help="Enable debug output")
    
    args = parser.parse_args()
    
    # Configuration
    num_tables = args.tables
    rows_per_table = args.rows
    cols_per_table = args.cols
    batch_size = args.batch_size
    num_threads = args.threads
    
    print(f"{Colors.BLUE}{'='*40}{Colors.NC}")
    print(f"{Colors.BLUE}  Fast PostgreSQL Stress Test (Python){Colors.NC}")
    print(f"{Colors.BLUE}{'='*40}{Colors.NC}")
    print()
    print("Configuration:")
    print(f"  Database: {Colors.GREEN}{args.database}{Colors.NC}")
    print(f"  Host:Port: {Colors.GREEN}{args.host}:{args.port}{Colors.NC}")
    print(f"  Tables: {Colors.GREEN}{num_tables}{Colors.NC}")
    print(f"  Rows per table: {Colors.GREEN}{rows_per_table}{Colors.NC}")
    print(f"  Columns per table: {Colors.GREEN}{cols_per_table}{Colors.NC}")
    print(f"  Batch size: {Colors.GREEN}{batch_size}{Colors.NC}")
    print(f"  Threads: {Colors.GREEN}{num_threads}{Colors.NC}")
    print()
    
    # Test connection
    print(f"{Colors.YELLOW}Checking database connectivity...{Colors.NC}")
    try:
        test_conn = psycopg2.connect(
            host=args.host,
            port=args.port,
            database=args.database,
            user=args.user,
            password=args.password
        )
        test_conn.close()
        print(f"{Colors.GREEN}✓ Database connection successful{Colors.NC}")
    except Exception as e:
        print(f"{Colors.RED}ERROR: Could not connect to database: {e}{Colors.NC}")
        sys.exit(1)
    print()
    
    # Create connection pool
    pool = ThreadedConnectionPool(
        minconn=1,
        maxconn=num_threads + 2,
        host=args.host,
        port=args.port,
        database=args.database,
        user=args.user,
        password=args.password
    )
    
    start_time = time.time()
    
    # Create tables (each with random names and random column definitions)
    print(f"{Colors.YELLOW}Creating {num_tables} tables with random names...{Colors.NC}")
    print(f"{Colors.YELLOW}Writing to HAProxy write port: {args.host}:{args.port}{Colors.NC}")
    print()
    
    # Store column definitions for each table (for later use in inserts)
    table_columns = {}
    
    conn = pool.getconn()
    try:
        created_count = 0
        max_attempts = num_tables * 3  # Allow some retries for name collisions
        attempts = 0
        
        while created_count < num_tables and attempts < max_attempts:
            # Generate random table name
            table_name = generate_table_name()
            attempts += 1
            
            # Skip if table already exists
            if table_exists(conn, table_name):
                continue
            
            # Generate random column definitions for each table
            columns = generate_column_definitions(cols_per_table)
            if create_table(conn, table_name, columns):
                # Only add to table_columns if table was successfully created
                table_columns[table_name] = columns
                created_count += 1
                print_progress(created_count, num_tables)
        
        print()
        if created_count == num_tables:
            print(f"{Colors.GREEN}✓ All {num_tables} new tables created{Colors.NC}")
        else:
            print(f"{Colors.YELLOW}⚠ Created {created_count} out of {num_tables} tables{Colors.NC}")
            if attempts >= max_attempts:
                print(f"{Colors.YELLOW}  (Reached max attempts, may have hit name collisions){Colors.NC}")
    finally:
        pool.putconn(conn)
    print()
    
    # Get the list of table names that were actually created
    table_names_list = sorted(table_columns.keys())
    actual_num_tables = len(table_names_list)
    
    # Insert data
    print(f"{Colors.YELLOW}Inserting {rows_per_table} rows into each table ({actual_num_tables} tables)...{Colors.NC}")
    print(f"{Colors.YELLOW}Writing to HAProxy write port: {args.host}:{args.port}{Colors.NC}")
    print()
    
    total_rows = 0
    total_inserts = actual_num_tables * rows_per_table
    current_inserts = 0
    import threading
    progress_lock = threading.Lock()
    
    def insert_table_data(table_name: str) -> int:
        """Insert all data for a single table"""
        nonlocal current_inserts
        # Get the column definitions for this specific table
        columns = table_columns[table_name]
        conn = pool.getconn()
        rows_inserted = 0
        
        try:
            # Calculate batches
            num_batches = (rows_per_table + batch_size - 1) // batch_size
            
            for batch_num in range(1, num_batches + 1):
                rows_in_batch = min(batch_size, rows_per_table - (batch_num - 1) * batch_size)
                
                # Generate batch data
                batch_data = [generate_row_values(columns) for _ in range(rows_in_batch)]
                
                # Insert batch
                inserted = insert_batch(conn, table_name, columns, batch_data, batch_num, num_batches)
                rows_inserted += inserted
                
                # Update progress (thread-safe)
                with progress_lock:
                    current_inserts += inserted
                    # Update progress more frequently for better feedback
                    if batch_num % 5 == 0 or batch_num == num_batches:
                        print_progress(current_inserts, total_inserts)
            
            # Final progress update for this table
            with progress_lock:
                print_progress(current_inserts, total_inserts)
        finally:
            pool.putconn(conn)
        
        return rows_inserted
    
    # Insert data in parallel
    with ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = {executor.submit(insert_table_data, table_name): table_name for table_name in table_names_list}
        for future in as_completed(futures):
            total_rows += future.result()
    
    print()
    print(f"{Colors.GREEN}✓ All data inserted ({total_rows} total rows){Colors.NC}")
    print()
    
    # Update rows
    print(f"{Colors.YELLOW}Updating random rows (10% of each table)...{Colors.NC}")
    update_count = max(1, rows_per_table // 10)
    
    conn = pool.getconn()
    try:
        for idx, table_name in enumerate(table_names_list, 1):
            columns = table_columns[table_name]
            if update_table(conn, table_name, update_count, columns):
                print_progress(idx, len(table_names_list))
        print()
        print(f"{Colors.GREEN}✓ Updates completed{Colors.NC}")
    finally:
        pool.putconn(conn)
    print()
    
    # Run test queries
    print(f"{Colors.YELLOW}Running test queries...{Colors.NC}")
    conn = pool.getconn()
    try:
        for i in range(1, 6):
            table_name = random.choice(table_names_list) if table_names_list else f"stress_table_{random.randint(1, num_tables):03d}"
            print(f"  Query {i}/5: SELECT COUNT(*) FROM {table_name}...")
            count = query_table(conn, table_name)
            if count > 0:
                print(f"    {Colors.GREEN}✓{Colors.NC} Count: {count} rows")
            else:
                print(f"    {Colors.RED}✗{Colors.NC} Error running query")
    finally:
        pool.putconn(conn)
    print()
    
    # Database statistics
    print(f"{Colors.YELLOW}Database Statistics:{Colors.NC}")
    conn = pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT COUNT(*) FROM information_schema.tables 
                WHERE table_schema = 'public' AND table_name LIKE 'stress_table_%';
            """)
            total_tables = cur.fetchone()[0]
            
            cur.execute("""
                SELECT SUM(n_live_tup) FROM pg_stat_user_tables 
                WHERE schemaname = 'public' AND relname LIKE 'stress_table_%';
            """)
            total_rows_count = cur.fetchone()[0] or 0
            
            cur.execute(f"SELECT pg_size_pretty(pg_database_size('{args.database}'));")
            db_size = cur.fetchone()[0]
    finally:
        pool.putconn(conn)
    
    end_time = time.time()
    duration = int(end_time - start_time)
    
    print(f"  Total tables created: {Colors.GREEN}{total_tables}{Colors.NC}")
    print(f"  Total rows inserted: {Colors.GREEN}{total_rows_count}{Colors.NC}")
    print(f"  Database size: {Colors.GREEN}{db_size}{Colors.NC}")
    print(f"  Duration: {Colors.GREEN}{duration}{Colors.NC} seconds")
    print()
    
    print(f"{Colors.BLUE}{'='*40}{Colors.NC}")
    print(f"{Colors.GREEN}Stress test completed successfully!{Colors.NC}")
    print(f"{Colors.BLUE}{'='*40}{Colors.NC}")
    print()
    print("To clean up the test data, run:")
    print(f"  {Colors.YELLOW}./scripts/testing/cleanup_stress_test.sh{Colors.NC}")
    print()
    
    # Close connection pool
    pool.closeall()

if __name__ == "__main__":
    main()

