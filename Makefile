.PHONY: help up down restart logs ps build clean status shell-db1 shell-db2 shell-db3 shell-db4 shell-etcd1 shell-haproxy shell-barman shell show-backups check backup list-backups check-archive pitr monitor-recovery vacuum analyze pgbadger psql psql-read psql-node stats activity slow-queries switchover reinit failover test-ssh test-connectivity info config leader

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make backup SERVER=db1"
	@echo "  make show-backups SERVER=db1 BACKUP_ID=20260123T120000"
	@echo "  make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' SERVER=db1 TARGET=db2"
	@echo "  make vacuum --all-nodes"
	@echo "  make psql"
	@echo "  make leader"

# ============================================================================
# Container Management
# ============================================================================

up: ## Start all containers
	docker-compose up -d

down: ## Stop all containers
	docker-compose down

restart: ## Restart all containers
	docker-compose restart

logs: ## Follow logs from all containers
	docker-compose logs -f

ps: ## Show container status
	docker-compose ps

build: ## Rebuild all Docker images (no cache)
	docker-compose build --no-cache

clean: ## Remove all containers, volumes, and prune system
	docker-compose down -v
	docker system prune -f

# ============================================================================
# Health & Monitoring
# ============================================================================

check: ## Run comprehensive health check (check_stack.sh)
	@./check_stack.sh

status: ## Show cluster status (Patroni, etcd, HAProxy)
	@echo "=== Patroni Cluster Status ==="
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list || echo "Patroni not ready yet"
	@echo ""
	@echo "=== etcd Cluster Health ==="
	@docker exec etcd1 etcdctl endpoint health || echo "etcd not ready yet"
	@echo ""
	@echo "=== HAProxy Stats ==="
	@echo "Visit http://localhost:$${HAPROXY_STATS_PORT:-5553}/stats"

info: ## Show detailed stack information (JSON or human-readable)
	@if [ "$(FORMAT)" = "json" ]; then \
		bash scripts/debug/get_stack_info.sh --json; \
	else \
		bash scripts/debug/get_stack_info.sh --human; \
	fi

leader: ## Show current leader node
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print "Leader: " $$2}'

# ============================================================================
# Backup Operations
# ============================================================================

backup: ## Create backup (auto-detects leader, or use SERVER=db1 to override)
	@echo "=== Step 1: Patroni Cluster Status ==="
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || (echo "Error: Patroni not accessible"; exit 1)
	@echo ""
	@echo "=== Step 2: Detecting Leader ==="
	@SERVER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}' || echo ""); \
	if [ -z "$$SERVER" ]; then \
		echo "Error: Could not detect leader. Is Patroni running?"; \
		exit 1; \
	fi; \
	if [ -n "$(SERVER)" ]; then \
		SERVER=$(SERVER); \
		echo "Using specified server: $$SERVER (overriding leader detection)"; \
	else \
		echo "Leader detected: $$SERVER"; \
	fi; \
	echo ""; \
	echo "=== Step 3: Barman Check ==="; \
	docker exec barman barman check $$SERVER; \
	CHECK_EXIT=$$?; \
	if [ $$CHECK_EXIT -ne 0 ]; then \
		echo ""; \
		echo "⚠️  Warning: Barman check failed (exit code: $$CHECK_EXIT)"; \
		echo "Backup may still proceed, but issues detected."; \
		echo ""; \
	fi; \
	echo ""; \
	echo "=== Step 4: Creating Backup ==="; \
	echo "Creating backup of $$SERVER..."; \
	docker exec barman barman backup $$SERVER; \
	BACKUP_EXIT=$$?; \
	if [ $$BACKUP_EXIT -eq 0 ]; then \
		echo ""; \
		echo "✓ Backup created successfully"; \
		echo ""; \
		echo "=== Step 5: Listing Backups ==="; \
		docker exec barman barman list-backup $$SERVER | head -10; \
		echo ""; \
		echo "To see full backup list: make list-backups SERVER=$$SERVER"; \
	else \
		echo ""; \
		echo "✗ Backup failed (exit code: $$BACKUP_EXIT)"; \
		echo "Check Barman logs: docker logs barman"; \
		exit $$BACKUP_EXIT; \
	fi

list-backups: ## List backups (auto-detects leader, or use SERVER=db1 to override)
	@if [ -z "$(SERVER)" ]; then \
		echo "Detecting current leader..."; \
		SERVER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}' || echo ""); \
		if [ -z "$$SERVER" ]; then \
			echo "Error: Could not detect leader. Listing backups for all servers:"; \
			echo ""; \
			for s in db1 db2 db3 db4; do \
				echo "=== $$s ==="; \
				docker exec barman barman list-backup $$s 2>/dev/null || echo "No backups or server not configured"; \
				echo ""; \
			done; \
			exit 0; \
		fi; \
		echo "Leader detected: $$SERVER"; \
	else \
		SERVER=$(SERVER); \
		echo "Using specified server: $$SERVER"; \
	fi; \
	echo "=== Backups for $$SERVER ==="; \
	docker exec barman barman list-backup $$SERVER

show-backups: ## Show backup details (usage: make show-backups SERVER=db1 BACKUP_ID=20260123T120000)
	@if [ -z "$(SERVER)" ] || [ -z "$(BACKUP_ID)" ]; then \
		echo "Usage: make show-backups SERVER=db1 BACKUP_ID=20260123T120000"; \
		echo ""; \
		echo "To list available backups:"; \
		echo "  make list-backups SERVER=db1"; \
		exit 1; \
	fi
	@docker exec barman barman show-backup $(SERVER) $(BACKUP_ID)

check-archive: ## Check WAL archiving status on leader
	@bash scripts/backup/check_archive_command.sh

# ============================================================================
# Recovery Operations
# ============================================================================

pitr: ## Point-in-time recovery (usage: make pitr BACKUP_ID=xxx TARGET_TIME='2026-01-23 12:30:00' SERVER=db1 TARGET=db2)
	@if [ -z "$(BACKUP_ID)" ] || [ -z "$(TARGET_TIME)" ]; then \
		echo "Usage: make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' SERVER=db1 TARGET=db2"; \
		echo ""; \
		echo "Optional flags:"; \
		echo "  --restore        Apply recovery to target node"; \
		echo "  --auto-start     Auto-start PostgreSQL after recovery"; \
		echo "  --wal-method     barman-wal-restore (default) or barman-get-wal"; \
		exit 1; \
	fi
	@bash scripts/pitr/perform_pitr.sh $(BACKUP_ID) "$(TARGET_TIME)" \
		--server $(SERVER) \
		$(if $(TARGET),--target $(TARGET),) \
		$(filter-out $@,$(MAKECMDGOALS))

monitor-recovery: ## Monitor recovery progress (usage: make monitor-recovery NODE=db2)
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make monitor-recovery NODE=db2"; \
		exit 1; \
	fi
	@bash scripts/pitr/monitor_recovery.sh $(NODE)

# ============================================================================
# Maintenance Operations
# ============================================================================

vacuum: ## Run VACUUM ANALYZE (usage: make vacuum NODE=db1, or make vacuum --all-nodes)
	@bash scripts/maintenance/vacuum_optimize.sh $(filter-out $@,$(MAKECMDGOALS))

analyze: ## Run ANALYZE only (usage: make analyze NODE=db1)
	@bash scripts/maintenance/vacuum_optimize.sh --type analyze $(filter-out $@,$(MAKECMDGOALS))

pgbadger: ## Generate pgBadger report (usage: make pgbadger NODE=db1)
	@if [ -z "$(NODE)" ]; then \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
		echo "Auto-detected leader: $$NODE"; \
		NODE=$$NODE; \
	else \
		NODE=$(NODE); \
	fi
	@bash scripts/maintenance/generate_pgbadger_report.sh --node $$NODE

# ============================================================================
# Database Operations
# ============================================================================

psql: ## Connect to database via HAProxy write endpoint (default: maborak database)
	@psql -h localhost -p $${HAPROXY_WRITE_PORT:-5551} -U postgres -d $${DATABASE:-maborak}

psql-read: ## Connect to database via HAProxy read endpoint (replicas)
	@psql -h localhost -p $${HAPROXY_READ_PORT:-5552} -U postgres -d $${DATABASE:-maborak}

psql-node: ## Connect directly to specific node (usage: make psql-node NODE=db1)
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make psql-node NODE=db1"; \
		exit 1; \
	fi
	@docker exec -it $(NODE) psql -U postgres -d $${DATABASE:-maborak}

stats: ## Show database statistics (usage: make stats NODE=db1)
	@if [ -z "$(NODE)" ]; then \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
		echo "Auto-detected leader: $$NODE"; \
		NODE=$$NODE; \
	else \
		NODE=$(NODE); \
	fi
	@bash scripts/debug/count_database_stats.sh $$NODE

activity: ## Monitor database activity with pg_activity (usage: make activity NODE=db1)
	@if [ -z "$(NODE)" ]; then \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
		echo "Auto-detected leader: $$NODE"; \
		NODE=$$NODE; \
	else \
		NODE=$(NODE); \
	fi
	@bash scripts/debug/pg_activity_monitor.sh --node $$NODE

slow-queries: ## Show slow queries from pg_stat_statements (usage: make slow-queries NODE=db1 LIMIT=10)
	@if [ -z "$(NODE)" ]; then \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
		echo "Auto-detected leader: $$NODE"; \
		NODE=$$NODE; \
	else \
		NODE=$(NODE); \
	fi
	@bash scripts/debug/pg_stat_statements_query.sh --node $$NODE $(if $(LIMIT),--limit $(LIMIT),--limit 10)

# ============================================================================
# Cluster Operations
# ============================================================================

switchover: ## Perform planned switchover (usage: make switchover NEW_LEADER=db2)
	@if [ -z "$(NEW_LEADER)" ]; then \
		echo "Usage: make switchover NEW_LEADER=db2"; \
		echo ""; \
		echo "Current cluster status:"; \
		@docker exec db1 patronictl -c /etc/patroni/patroni.yml list; \
		exit 1; \
	fi
	@echo "Performing switchover to $(NEW_LEADER)..."
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml switchover --master $(NEW_LEADER) --force
	@echo "Switchover complete. New status:"
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list

reinit: ## Reinitialize replica (usage: make reinit NODE=db2)
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make reinit NODE=db2"; \
		exit 1; \
	fi
	@echo "⚠️  WARNING: This will destroy all data on $(NODE)!"
	@echo "Type 'REINIT' to confirm:"
	@read -r confirm && [ "$$confirm" = "REINIT" ] || exit 1
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml reinit $(NODE)
	@echo "Reinit complete. Monitor with: make status"

failover: ## Force failover (emergency only, usage: make failover NEW_LEADER=db2)
	@if [ -z "$(NEW_LEADER)" ]; then \
		echo "Usage: make failover NEW_LEADER=db2"; \
		echo ""; \
		echo "⚠️  WARNING: This is a FORCE failover. Use only in emergencies!"; \
		exit 1; \
	fi
	@echo "⚠️  WARNING: FORCE FAILOVER to $(NEW_LEADER)!"
	@echo "Type 'FAILOVER' to confirm:"
	@read -r confirm && [ "$$confirm" = "FAILOVER" ] || exit 1
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml failover --master $(NEW_LEADER) --force
	@echo "Failover complete. New status:"
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# ============================================================================
# Testing & Connectivity
# ============================================================================

test-ssh: ## Test SSH connectivity (all nodes to Barman and vice versa)
	@bash scripts/utils/test_ssh_to_barman.sh
	@echo ""
	@bash scripts/utils/test_barman_ssh_to_patroni.sh

test-connectivity: ## Test PostgreSQL connectivity from Barman
	@bash scripts/utils/test_barman_postgres_connectivity.sh

# ============================================================================
# Shell Access
# ============================================================================

shell-db1: ## Open bash shell in db1 container
	docker exec -it db1 bash

shell-db2: ## Open bash shell in db2 container
	docker exec -it db2 bash

shell-db3: ## Open bash shell in db3 container
	docker exec -it db3 bash

shell-db4: ## Open bash shell in db4 container
	docker exec -it db4 bash

shell-etcd1: ## Open shell in etcd1 container
	docker exec -it etcd1 sh

shell-haproxy: ## Open shell in haproxy container
	docker exec -it haproxy sh

shell-barman: ## Open bash shell in barman container
	docker exec -it barman bash

shell: ## Open shell in specified node (usage: make shell NODE=db1)
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make shell NODE=db1"; \
		echo "Or use: make shell-db1, make shell-barman, etc."; \
		exit 1; \
	fi
	@docker exec -it $(NODE) bash || docker exec -it $(NODE) sh

# ============================================================================
# Configuration
# ============================================================================

config: ## Show current configuration (ports, environment variables)
	@echo "=== Environment Variables ==="
	@cat .env 2>/dev/null || echo "No .env file (using defaults)"
	@echo ""
	@echo "=== Port Configuration ==="
	@echo "HAProxy Write: $${HAPROXY_WRITE_PORT:-5551}"
	@echo "HAProxy Read: $${HAPROXY_READ_PORT:-5552}"
	@echo "HAProxy Stats: http://localhost:$${HAPROXY_STATS_PORT:-5553}/stats"
	@echo "PostgreSQL (db1): $${PATRONI_DB1_PORT:-15431}"
	@echo "PostgreSQL (db2): $${PATRONI_DB2_PORT:-15432}"
	@echo "PostgreSQL (db3): $${PATRONI_DB3_PORT:-15433}"
	@echo "PostgreSQL (db4): $${PATRONI_DB4_PORT:-15434}"

# Allow passing extra arguments to targets
%:
	@:
