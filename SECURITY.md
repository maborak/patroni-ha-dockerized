# Security Policy

## Supported versions

Only the latest `main` branch receives fixes.

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Please email the maintainer (see [LICENSE](LICENSE) for the copyright holder's
name and the GitHub profile for contact details) with:

- a description of the issue and its impact,
- reproduction steps (config, commands),
- any suggested mitigation.

You will get an acknowledgement within a few days. We credit reporters in the
fix commit unless you prefer to remain anonymous.

## Scope notes

This project ships a **lab-oriented** Docker Compose stack:

- Default passwords and the default HAProxy stats credentials in
  `.env.example` are placeholders — change them before running anything
  reachable by others.
- etcd, the Patroni REST API, per-node PostgreSQL, and Barman ports are
  published on the Docker host (localhost by default). Restrict access with a
  firewall/VPN before exposing the stack beyond localhost.
- `.env`, SSH keys (`ssh_keys/`), and generated `configs/` are gitignored;
  never commit real credentials or topology files.
