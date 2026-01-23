#!/bin/bash
# Health check script for HAProxy to check if a node is a replica
# Returns 0 (success) if the node is a replica, 1 (failure) otherwise

response=$(curl -s http://${1:-localhost}:${2:-8001}/patroni 2>/dev/null)
if [ -z "$response" ]; then
    exit 1
fi

role=$(echo "$response" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('role', ''))" 2>/dev/null)

if [ "$role" = "replica" ]; then
    exit 0
else
    exit 1
fi

