.PHONY: help generate setup-keys up wizard down restart logs ps build destroy status shell-db1 shell-db2 shell-db3 shell-db4 shell-etcd1 shell-haproxy shell-barman shell show-backups check smoke-test backup dump-db restore-db list-backups check-archive pitr monitor-recovery vacuum analyze pgbadger psql psql-read psql-node list-dbs stats activity slow-queries switchover reinit failover switchover-to-remote switchover-from-remote test-ssh test-connectivity info config leader disk

.DEFAULT_GOAL := help

setup-keys: ## Ensure SSH keypair exists in ssh_keys/ (auto-generated if missing)
	@bash scripts/utils/setup_ssh_keys.sh

generate: setup-keys ## Generate all configs from templates (uses values from .env)
	@bash scripts/generate_configs.sh


help: ## Show this help message
	@echo "Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make backup SERVER=db1"
	@echo "  make show-backups SERVER=db1 BACKUP_ID=20260123T120000"
	@echo "  make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' SERVER=db1 TARGET=db2"
	@echo "  make vacuum ALL=1"
	@echo "  make psql"
	@echo "  make leader"

# ============================================================================
# Container Management
# ============================================================================

up: ## Start all containers (non-interactive; for guided flow use: make wizard)
	@bash scripts/generate_configs.sh
	docker-compose up -d --remove-orphans
	@echo ""
	@echo "Tip: 'make wizard' for the guided menu, 'make status' for endpoints, 'make check' for a health check."

wizard: ## Step-by-step setup wizard: configure → review values → confirm → build (make wizard)
	@bash scripts/utils/wizard.sh

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

destroy: ## ⚠️ Destroy stack AND ALL DATA: containers, volumes (DB data, etcd, Barman backups). Confirm required (YES=1 to skip, PRUNE=1 to also prune docker system-wide)
	@if [ "$(YES)" != "1" ]; then \
		echo ""; \
		echo "============================================================"; \
		echo "  ⚠️  WARNING: DESTROYING THE PATRONI HA STACK  ⚠️"; \
		echo "============================================================"; \
		echo "This will PERMANENTLY DELETE:"; \
		echo "  - All containers (db1-dbN, etcd, haproxy, pgbouncer, barman)"; \
		echo "  - ALL PostgreSQL data volumes (leader + replicas)"; \
		echo "  - etcd cluster state"; \
		echo "  - ALL Barman backups and WAL archives"; \
		echo ""; \
		echo "There is NO undo. Backups on Docker volumes will be gone."; \
		echo "To save a backup first: make backup"; \
		echo ""; \
		printf "Type DESTROY to confirm (anything else aborts): "; \
		read -r confirm; \
		if [ "$$confirm" != "DESTROY" ]; then echo "Aborted."; exit 1; fi; \
	fi
	@docker-compose down -v
	@if [ "$(PRUNE)" = "1" ]; then \
		echo "Pruning unused Docker data (stopped containers, networks, dangling images)..."; \
		docker system prune -f; \
	fi
	@echo "Stack destroyed. To start fresh: make up"

# ============================================================================
# Health & Monitoring
# ============================================================================

check: ## Run comprehensive health check (check_stack.sh)
	@./check_stack.sh

smoke-test: ## Run end-to-end smoke tests (setup wizard + PITR wizard; sandboxed, no Docker needed)
	@bash scripts/testing/smoke_test_wizard.sh
	@bash scripts/testing/smoke_test_pitr.sh

status: ## Show cluster status, health, and all access endpoints (HAProxy, PgBouncer, nodes, Barman)
	@. ./.env 2>/dev/null; \
	LEADER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}'); \
	PGUSER=$${POSTGRES_USER:-postgres}; \
	PGDB=$${DEFAULT_DATABASE:-maborak}; \
	echo "=== Patroni Cluster Status ==="; \
	docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "Patroni not ready yet"; \
	echo ""; \
	echo "=== etcd Cluster Health ==="; \
	docker exec etcd1 etcdctl endpoint health 2>/dev/null || echo "etcd not ready yet"; \
	echo ""; \
	echo "=== Connection Endpoints (local cluster) ==="; \
	echo "  Write (HAProxy):    postgresql://$$PGUSER@localhost:$${HAPROXY_WRITE_PORT:-5551}/$$PGDB   [make psql]"; \
	echo "  Read  (HAProxy):    postgresql://$$PGUSER@localhost:$${HAPROXY_READ_PORT:-5552}/$$PGDB   [make psql-read]"; \
	echo "  Write (PgBouncer):  postgresql://$$PGUSER@localhost:$${PGBOUNCER_PORT:-6432}/$$PGDB"; \
	echo "  Read  (PgBouncer):  postgresql://$$PGUSER@localhost:$${PGBOUNCER_RO_PORT:-6433}/$$PGDB"; \
	if [ -n "$${REMOTE_HAPROXY_HOST:-}" ]; then \
		echo ""; \
		echo "  Remote standby cluster:"; \
		echo "  Write (HAProxy):    postgresql://$$PGUSER@$${REMOTE_HAPROXY_HOST}:$${REMOTE_HAPROXY_WRITE_PORT:-5511}/$$PGDB"; \
		echo "  Read  (HAProxy):    postgresql://$$PGUSER@$${REMOTE_HAPROXY_HOST}:$${REMOTE_HAPROXY_READ_PORT:-5521}/$$PGDB"; \
	fi; \
	echo ""; \
	echo "  Direct node access (bypasses HAProxy — no failover protection):"; \
	i=1; \
	while [ $$i -le $$(($${PATRONI_REPLICAS:-2} + 1)) ]; do \
		eval port="\$${PATRONI_DB$${i}_PORT}"; \
		port=$${port:-$$(( $${PATRONI_BASE_PORT:-15431} + i - 1 ))}; \
		eval api="\$${PATRONI_DB$${i}_API_PORT}"; \
		api=$${api:-$$(( $${PATRONI_API_BASE_PORT:-8001} + i - 1 ))}; \
		ROLE="replica"; \
		[ "db$$i" = "$$LEADER" ] && ROLE="LEADER"; \
		printf "  db%-2s   postgresql://%s@localhost:%s/%s   (Patroni API :%s)   [%s]\n" "$$i" "$$PGUSER" "$$port" "$$PGDB" "$$api" "$$ROLE"; \
		i=$$((i + 1)); \
	done; \
	echo ""; \
	echo "=== HAProxy Stats ==="; \
	echo "  http://localhost:$${HAPROXY_STATS_PORT:-5553}/stats"; \
	echo ""; \
	echo "=== Barman Backups ==="; \
	if [ -n "$$LEADER" ]; then \
		BACKUPS=$$(docker exec barman barman list-backup $$LEADER 2>/dev/null | head -5); \
		if [ -n "$$BACKUPS" ]; then echo "$$BACKUPS"; else echo "  No backups listed for $$LEADER — create one: make backup"; fi; \
	else \
		echo "  Leader unknown — list manually: make list-backups [SERVER=dbN]"; \
	fi; \
	echo "  Manage: make backup | make list-backups | make show-backups SERVER=dbN BACKUP_ID=<id>"

info: ## Show detailed stack information (JSON or human-readable)
	@if [ "$(FORMAT)" = "json" ]; then \
		bash scripts/debug/get_stack_info.sh --json; \
	else \
		bash scripts/debug/get_stack_info.sh --human; \
	fi

leader: ## Show current leader node
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print "Leader: " $$2}'

disk: ## Disk usage / cleanup (FORMAT=json | CLEANUP=logs|dumps|docker|snapshots|temp|barman|all [KEEP_DAYS=N] [DRYRUN=1])
	@if [ -n "$(CLEANUP)" ]; then \
		case "$(CLEANUP)" in \
			1|logs)    FLAG="--cleanup-logs" ;; \
			dumps)     FLAG="--cleanup-dumps" ;; \
			docker)    FLAG="--cleanup-docker" ;; \
			snapshots) FLAG="--cleanup-snapshots" ;; \
			temp)      FLAG="--cleanup-temp" ;; \
			barman)    FLAG="--cleanup-barman" ;; \
			all)       FLAG="--cleanup-all" ;; \
			*)         echo "Unknown CLEANUP value: $(CLEANUP). Valid: logs|dumps|docker|snapshots|temp|barman|all"; exit 1 ;; \
		esac; \
		bash scripts/debug/disk_usage.sh $$FLAG $(if $(KEEP_DAYS),--keep-days=$(KEEP_DAYS),) $(if $(DRYRUN),--dry-run,); \
	elif [ "$(FORMAT)" = "json" ]; then \
		bash scripts/debug/disk_usage.sh --json; \
	else \
		bash scripts/debug/disk_usage.sh; \
	fi

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
			. ./.env 2>/dev/null; for i in $$(seq 1 $$(($${PATRONI_REPLICAS:-2} + 1))); do s="db$$i"; \
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

dump-db: ## Logical .tgz backup of a single DB from a healthy replica (DB=name [NODE=db3] [JOBS=8] [OUTPUT=./backups] [YES=1])
	@bash scripts/backup/dump_database.sh \
		$(if $(DB),--db $(DB),--interactive) \
		$(if $(NODE),--node $(NODE),) \
		$(if $(JOBS),--jobs $(JOBS),) \
		$(if $(OUTPUT),--output $(OUTPUT),) \
		$(if $(filter 1,$(YES)),--yes,)

restore-db: ## Restore a DB from .tgz, local or remote (ARCHIVE=path [TARGET=name|URI] [JOBS=8] [CLEAN=1] [NO_OWNER=1] [NO_ACL=1] [YES=1] [DEBUG=1])
	@bash scripts/backup/restore_database.sh \
		$(if $(ARCHIVE),--archive $(ARCHIVE),--interactive) \
		$(if $(TARGET),--target $(TARGET),) \
		$(if $(NODE),--node $(NODE),) \
		$(if $(JOBS),--jobs $(JOBS),) \
		$(if $(filter 1,$(CLEAN)),--clean,) \
		$(if $(filter 1,$(NO_OWNER)),--no-owner,) \
		$(if $(filter 1,$(NO_ACL)),--no-acl,) \
		$(if $(filter 1,$(YES)),--yes,) \
		$(if $(filter 1,$(DEBUG)),--debug,)

# ============================================================================
# Recovery Operations
# ============================================================================

pitr: ## Point-in-time recovery wizard (no args = interactive; or make pitr BACKUP_ID=xxx TARGET_TIME='2026-01-23 12:30:00' [SERVER=db1] [TARGET=db2] [RESTORE=1] [AUTO_START=1] [WAL_METHOD=barman-get-wal])
	@if [ -z "$(BACKUP_ID)" ] && [ -z "$(TARGET_TIME)" ]; then \
		bash scripts/pitr/perform_pitr.sh; \
	elif [ -z "$(BACKUP_ID)" ] || [ -z "$(TARGET_TIME)" ]; then \
		echo "Usage: make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' SERVER=db1 TARGET=db2"; \
		echo ""; \
		echo "Or run 'make pitr' with no arguments for the interactive wizard."; \
		echo ""; \
		echo "Optional variables:"; \
		echo "  SERVER=db1          Server holding the backup (default: auto-detect)"; \
		echo "  TARGET=db2          Target node for recovery"; \
		echo "  RESTORE=1           Apply recovery to target node"; \
		echo "  AUTO_START=1        Auto-start PostgreSQL after recovery"; \
		echo "  WAL_METHOD=...      barman-wal-restore (default) or barman-get-wal"; \
		exit 1; \
	else \
		bash scripts/pitr/perform_pitr.sh $(BACKUP_ID) "$(TARGET_TIME)" \
			$(if $(SERVER),--server $(SERVER),) \
			$(if $(TARGET),--target $(TARGET),) \
			$(if $(filter 1,$(RESTORE)),--restore,) \
			$(if $(filter 1,$(AUTO_START)),--auto-start,) \
			$(if $(WAL_METHOD),--wal-method $(WAL_METHOD),); \
	fi

monitor-recovery: ## Monitor recovery progress (usage: make monitor-recovery NODE=db2)
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make monitor-recovery NODE=db2"; \
		exit 1; \
	fi
	@bash scripts/pitr/monitor_recovery.sh $(NODE)

# ============================================================================
# Maintenance Operations
# ============================================================================

vacuum: ## Run VACUUM ANALYZE (usage: make vacuum NODE=db1, or make vacuum ALL=1 for all nodes, TYPE=analyze|vacuum|full)
	@bash scripts/maintenance/vacuum_optimize.sh \
		$(if $(NODE),--node $(NODE),) \
		$(if $(filter 1,$(ALL)),--all-nodes,) \
		$(if $(TYPE),--type $(TYPE),)

analyze: ## Run ANALYZE only (usage: make analyze NODE=db1, or make analyze ALL=1)
	@bash scripts/maintenance/vacuum_optimize.sh --type analyze \
		$(if $(NODE),--node $(NODE),) \
		$(if $(filter 1,$(ALL)),--all-nodes,)

pgbadger: ## Generate pgBadger report (usage: make pgbadger NODE=db1)
	@if [ -n "$(NODE)" ]; then \
		bash scripts/maintenance/generate_pgbadger_report.sh --node $(NODE); \
	else \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}'); \
		if [ -z "$$NODE" ]; then echo "Error: Could not detect leader. Is Patroni running?" >&2; exit 1; fi; \
		echo "Auto-detected leader: $$NODE"; \
		bash scripts/maintenance/generate_pgbadger_report.sh --node $$NODE; \
	fi

# ============================================================================
# Database Operations
# ============================================================================

psql: ## Connect to database via HAProxy write endpoint (default: maborak database)
	@. ./.env 2>/dev/null; psql -h localhost -p $${HAPROXY_WRITE_PORT:-5551} -U $${POSTGRES_USER:-postgres} -d $${DEFAULT_DATABASE:-maborak}

psql-read: ## Connect to database via HAProxy read endpoint (replicas)
	@. ./.env 2>/dev/null; psql -h localhost -p $${HAPROXY_READ_PORT:-5552} -U $${POSTGRES_USER:-postgres} -d $${DEFAULT_DATABASE:-maborak}

psql-node: ## Connect directly to specific node (usage: make psql-node NODE=db1)
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make psql-node NODE=db1"; \
		exit 1; \
	fi
	@. ./.env 2>/dev/null; docker exec -it $(NODE) psql -U $${POSTGRES_USER:-postgres} -d $${DEFAULT_DATABASE:-maborak}

list-dbs: ## List databases on the leader (NODE=db2 to override, FORMAT=json for JSON, TEMPLATES=1 to include template DBs)
	@bash scripts/debug/list_databases.sh \
		$(if $(NODE),--node $(NODE),) \
		$(if $(filter json,$(FORMAT)),--json,) \
		$(if $(filter 1,$(TEMPLATES)),--include-templates,)

stats: ## Show database statistics (usage: make stats NODE=db1)
	@if [ -n "$(NODE)" ]; then \
		bash scripts/debug/count_database_stats.sh $(NODE); \
	else \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}'); \
		if [ -z "$$NODE" ]; then echo "Error: Could not detect leader. Is Patroni running?" >&2; exit 1; fi; \
		echo "Auto-detected leader: $$NODE"; \
		bash scripts/debug/count_database_stats.sh $$NODE; \
	fi

activity: ## Monitor database activity with pg_activity (usage: make activity NODE=db1)
	@if [ -n "$(NODE)" ]; then \
		bash scripts/debug/pg_activity_monitor.sh --node $(NODE); \
	else \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}'); \
		if [ -z "$$NODE" ]; then echo "Error: Could not detect leader. Is Patroni running?" >&2; exit 1; fi; \
		echo "Auto-detected leader: $$NODE"; \
		bash scripts/debug/pg_activity_monitor.sh --node $$NODE; \
	fi

slow-queries: ## Show slow queries from pg_stat_statements (usage: make slow-queries NODE=db1 LIMIT=10)
	@if [ -n "$(NODE)" ]; then \
		bash scripts/debug/pg_stat_statements_query.sh --node $(NODE) $(if $(LIMIT),--limit $(LIMIT),--limit 10); \
	else \
		NODE=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}'); \
		if [ -z "$$NODE" ]; then echo "Error: Could not detect leader. Is Patroni running?" >&2; exit 1; fi; \
		echo "Auto-detected leader: $$NODE"; \
		bash scripts/debug/pg_stat_statements_query.sh --node $$NODE $(if $(LIMIT),--limit $(LIMIT),--limit 10); \
	fi

# ============================================================================
# Cluster Operations
# ============================================================================

switchover: ## Perform planned switchover (usage: make switchover NEW_LEADER=db2)
	@if [ -z "$(NEW_LEADER)" ]; then \
		echo "Usage: make switchover NEW_LEADER=db2"; \
		echo ""; \
		echo "Current cluster status:"; \
		docker exec db1 patronictl -c /etc/patroni/patroni.yml list; \
		exit 1; \
	fi
	@CURRENT=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep Leader | awk '{print $$2}'); \
	if [ -z "$$CURRENT" ]; then \
		echo "Error: Could not detect leader. Is Patroni running?"; \
		exit 1; \
	fi; \
	if [ "$$CURRENT" = "$(NEW_LEADER)" ]; then \
		echo "Error: $(NEW_LEADER) is already the leader."; \
		exit 1; \
	fi; \
	echo "Performing switchover $$CURRENT -> $(NEW_LEADER)..."; \
	docker exec db1 patronictl -c /etc/patroni/patroni.yml switchover --leader $$CURRENT --candidate $(NEW_LEADER) --force || exit 1
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
	@. ./.env 2>/dev/null; docker exec db1 patronictl -c /etc/patroni/patroni.yml reinit $${PATRONI_CLUSTER_NAME:-patroni1} $(NODE) --force || exit 1
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
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml failover --candidate $(NEW_LEADER) --force || exit 1
	@echo "Failover complete. New status:"
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# ============================================================================
# Cross-cluster switchover (Mac ↔ Remote standby cluster)
# See docs/switchover.md for the full procedure.
# ============================================================================

switchover-to-remote: ## Cross-cluster: Mac → Remote (forward). YES=1 skips prompts. DRY_RUN=1 dry-run. SKIP_BACKUP=1.
	@FLAGS=""; \
	[ "$(YES)" = "1" ]         && FLAGS="$$FLAGS --yes"; \
	[ "$(DRY_RUN)" = "1" ]     && FLAGS="$$FLAGS --dry-run"; \
	[ "$(SKIP_BACKUP)" = "1" ] && FLAGS="$$FLAGS --skip-backup"; \
	bash scripts/ops/switchover_to_remote.sh $$FLAGS

switchover-from-remote: ## Cross-cluster: Remote → Mac (reverse). YES=1 skips prompts. DRY_RUN=1 dry-run. SKIP_BACKUP=1.
	@FLAGS=""; \
	[ "$(YES)" = "1" ]         && FLAGS="$$FLAGS --yes"; \
	[ "$(DRY_RUN)" = "1" ]     && FLAGS="$$FLAGS --dry-run"; \
	[ "$(SKIP_BACKUP)" = "1" ] && FLAGS="$$FLAGS --skip-backup"; \
	bash scripts/ops/switchover_from_remote.sh $$FLAGS

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
	@. ./.env 2>/dev/null; \
	echo "=== Port Configuration ==="; \
	echo "HAProxy Write: $${HAPROXY_WRITE_PORT:-5551}"; \
	echo "HAProxy Read: $${HAPROXY_READ_PORT:-5552}"; \
	echo "HAProxy Stats: http://localhost:$${HAPROXY_STATS_PORT:-5553}/stats"; \
	for i in $$(seq 1 $$(($${PATRONI_REPLICAS:-2} + 1))); do \
		port=$$(( $${PATRONI_BASE_PORT:-15431} + i - 1 )); \
		echo "PostgreSQL (db$$i): $$port"; \
	done
