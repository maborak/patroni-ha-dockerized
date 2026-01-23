#!/bin/bash
# Post-bootstrap script to create additional databases
# This script runs after Patroni initializes the cluster

set -e

# Get database name from environment variable (default: maborak)
DEFAULT_DATABASE="${DEFAULT_DATABASE:-maborak}"

# Get the connection string from Patroni (first argument)
CONN_URL="${1:-}"

# If no connection URL provided, try to connect via socket on port 5431
if [ -z "$CONN_URL" ]; then
    # Wait for PostgreSQL to be ready on port 5431
    until psql -U postgres -p 5431 -h localhost -c "SELECT 1" > /dev/null 2>&1; do
        echo "Waiting for PostgreSQL to be ready..."
        sleep 1
    done
    
    # Create database
    echo "Creating ${DEFAULT_DATABASE} database..."
    if psql -U postgres -p 5431 -h localhost -lqt | cut -d \| -f 1 | grep -qw "${DEFAULT_DATABASE}"; then
        echo "Database '${DEFAULT_DATABASE}' already exists, skipping creation."
    else
        psql -U postgres -p 5431 -h localhost -c "CREATE DATABASE ${DEFAULT_DATABASE};" && echo "Database '${DEFAULT_DATABASE}' created successfully."
    fi
    
    # Enable pg_stat_statements extension for query statistics (in postgres and application database)
    echo "Enabling pg_stat_statements extension..."
    psql -U postgres -p 5431 -h localhost -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 || echo "Note: pg_stat_statements extension may require server restart if not in shared_preload_libraries"
    psql -U postgres -p 5431 -h localhost -d "${DEFAULT_DATABASE}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 || echo "Note: pg_stat_statements extension may require server restart if not in shared_preload_libraries"
else
    # Use the connection URL provided by Patroni
    echo "Creating ${DEFAULT_DATABASE} database using connection URL..."
    psql "$CONN_URL" -c "CREATE DATABASE ${DEFAULT_DATABASE};" 2>&1 || {
        if psql "$CONN_URL" -lqt | cut -d \| -f 1 | grep -qw "${DEFAULT_DATABASE}"; then
            echo "Database '${DEFAULT_DATABASE}' already exists, skipping creation."
        else
            echo "Failed to create ${DEFAULT_DATABASE} database"
            exit 1
        fi
    }
    
    # Enable pg_stat_statements extension for query statistics (in postgres and application database)
    echo "Enabling pg_stat_statements extension..."
    DB_CONN_URL="${CONN_URL%/postgres}"  # Remove /postgres suffix if present
    psql "$CONN_URL" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 || echo "Note: pg_stat_statements extension may require server restart if not in shared_preload_libraries"
    psql "${DB_CONN_URL}/${DEFAULT_DATABASE}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 || echo "Note: pg_stat_statements extension may require server restart if not in shared_preload_libraries"
fi

echo "Post-bootstrap script completed successfully"

