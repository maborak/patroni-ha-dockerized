# Contributing to Patroni HA Dockerized

Thanks for your interest in improving this project.

## Getting started

```bash
git clone <your-fork>
cd patroni-ha-dockerized
cp .env.example .env   # edit passwords before starting anything
make smoke-test        # must pass before and after your changes
```

`make smoke-test` runs the setup-wizard and PITR-wizard tests in a sandbox with
stubbed `docker` binaries — no Docker daemon or running cluster is required.

## Ground rules

- **`make smoke-test` must pass.** If you touch the wizard
  (`scripts/utils/wizard.sh`), config generation (`scripts/generate_configs.sh`),
  the PITR script (`scripts/pitr/perform_pitr.sh`), or Makefile target routing,
  extend the corresponding test in `scripts/testing/` to cover your change.
- **Bash hygiene**: `bash -n` clean, `set -euo pipefail` where practical,
  source `scripts/lib/common.sh` for node discovery / leader detection instead
  of hardcoding node names.
- **No hardcoded topology.** Node count, cluster name, and ports come from
  `.env` (`PATRONI_REPLICAS`, `PATRONI_CLUSTER_NAME`, …). Never assume `db1–db4`
  or a fixed cluster name in code or docs.
- **No secrets or private infrastructure.** Use RFC 5737 documentation IPs
  (`192.0.2.x`, `198.51.100.x`) or `.env` variable names in examples. Never
  commit `.env`, SSH keys, or generated `configs/` (all gitignored).
- **Generated files are build artifacts.** `docker-compose.yml`,
  `configs/*.cfg|*.ini`, and `barman/supervisord.conf` are produced by
  `make generate` from `templates/` — change the templates, not the output.

## Docs

Docs live in [docs/](docs/) and [scripts/README.md](scripts/README.md). If your
change alters behavior (new flag, new make target, changed default), update the
relevant doc in the same PR.

## Pull requests

1. Keep PRs focused; one logical change per PR.
2. Describe what changed and why; link any related issue.
3. Confirm `make smoke-test` passes and note any manual testing you did
   against a real cluster.

## Reporting bugs / security issues

- Bugs: open an issue with reproduction steps and `make status` /
  `make check` output (redact secrets).
- Security: see [SECURITY.md](SECURITY.md) — please do not open public issues
  for vulnerabilities.
