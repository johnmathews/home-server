# Fix duplicate host port: documentation-ui and Homepage both on 3002

**Date:** 2026-03-28

## Problem

The root domain `itsa-pizza.com` wasn't serving the Homepage dashboard. Investigation revealed two issues:

1. **Cloudflare Access** was intercepting the root domain with a login redirect (302 to
   `itsapizza.cloudflareaccess.com`), preventing unauthenticated access to Homepage.
2. **Duplicate host port binding** — both `documentation-ui` and `homepage` services in the infra VM
   docker-compose template were mapped to host port `3002`. Docker Compose does not error on this;
   whichever container starts first claims the port, and the other silently fails to bind.

## Fix

- Moved `documentation-ui` from port `3002` to `3003` in the docker-compose template.
- Updated the cloudflared ingress route for `docs.itsa-pizza.com` to point to port `3003`.
- Updated documentation in `infra_vm.md` (port table, description, routing table).

## Prevention: duplicate port checker

Added `scripts/check-duplicate-ports.py` — scans all 11 docker-compose Jinja2 templates for duplicate
host port bindings within the same file. Protocol-aware (TCP and UDP on the same port number is valid,
e.g. Syncthing's `22000/tcp` + `22000/udp`).

Wired into the CI pipeline:
- `make check-ports` — standalone target
- `make ci` — now runs `lint` → `check-ports` → `check`

Added tests in `tests/test_check_duplicate_ports.py` (7 tests covering duplicates, TCP/UDP distinction,
quoted/unquoted ports, service name tracking, edge cases).

## Remaining

The Cloudflare Access issue (root domain behind Zero Trust login) is a separate configuration change
needed in the Cloudflare dashboard — not managed by Ansible.
