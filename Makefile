.PHONY: up down restart logs ps build clean

up:
	docker-compose up -d

down:
	docker-compose down

restart:
	docker-compose restart

logs:
	docker-compose logs -f

ps:
	docker-compose ps

build:
	docker-compose build --no-cache

clean:
	docker-compose down -v
	docker system prune -f

status:
	@echo "=== Patroni Cluster Status ==="
	@docker exec db1 patronictl -c /etc/patroni/patroni1.yml list || echo "Patroni not ready yet"
	@echo ""
	@echo "=== etcd Cluster Health ==="
	@docker exec etcd1 etcdctl endpoint health || echo "etcd not ready yet"
	@echo ""
	@echo "=== HAProxy Stats ==="
	@echo "Visit http://localhost:8404/stats"

shell-db1:
	docker exec -it db1 bash

shell-etcd1:
	docker exec -it etcd1 sh

shell-haproxy:
	docker exec -it haproxy sh

shell-barman:
	docker exec -it barman bash

