#!/bin/bash
# Script to create default database after Patroni bootstrap
# Called by Patroni post_bootstrap hook
# This script is built into the Patroni image at /etc/patroni/create_databases.sh

set -e

# Get default database name from environment variable (set in docker-compose.yml)
DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}

# PostgreSQL connection parameters
PGHOST=${PGHOST:-localhost}
PGPORT=${PGPORT:-5431}
PGUSER=${PGUSER:-postgres}

# Create database if it doesn't exist
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres <<EOF
SELECT 'CREATE DATABASE $DEFAULT_DATABASE'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DEFAULT_DATABASE')\gexec
EOF

# Verify database was created
if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DEFAULT_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "Database '$DEFAULT_DATABASE' created successfully"
else
    echo "Warning: Failed to create or verify database '$DEFAULT_DATABASE'"
    exit 1
fi
