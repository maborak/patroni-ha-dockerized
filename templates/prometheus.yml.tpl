# Rendered by scripts/generate_configs.sh → configs/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: patroni
    static_configs:
__PATRONI_TARGETS__

  - job_name: postgres-exporters
    static_configs:
      - targets:
__POSTGRES_EXPORTER_TARGETS__

  - job_name: haproxy
    static_configs:
      - targets: ["haproxy-exporter:9101"]
