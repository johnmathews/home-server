# 260613 — Library DB password rotation + paperless version-pin landmine

## What

The `library-db` Postgres password was hard-coded in
`roles/paperless_lxc/templates/.env.j2` (`LIBRARY_DB_PASSWORD=lib-pg-x7c2e9d41`)
and committed to a **public** repo. Moved it into Ansible Vault as
`vault_library_db_password` and rotated it to a fresh value.

## Steps taken

1. Added `vault_library_db_password` to `group_vars/all/vault.yml`; template now
   renders `LIBRARY_DB_PASSWORD={{ vault_library_db_password }}`.
2. Generated a fresh alphanumeric password (no URL/shell metacharacters, since it
   flows through both `.env` interpolation and the asyncpg DSN).
3. `make paperless TAGS=docker` to render the new `.env`.
4. `ALTER USER library WITH PASSWORD ...` inside the running `library-db`
   (volume already initialized, so `POSTGRES_PASSWORD` env alone wouldn't change it).
5. `docker compose up -d --pull never library-{db,migrate,webserver,worker}`.
6. Verified: migrate exit 0, webserver `/healthz` 200, new password authenticates,
   old password rejected.

## The landmine (important)

Re-rendering `.env` fired the `Restart all containers` handler, which re-rendered
`docker-compose.yml` too. The git defaults had **stale version pins** far below
the images actually running on the host:

    paperless 2.14.7 (running latest/2.18.4), cadvisor v0.49.1 (latest),
    node_exporter v1.8.2 (latest), alloy v1.5.1 (latest)

The handler (`recreate: always`, `pull: never`) tried to recreate everything down
to those versions. It happened to **fail on the missing `cadvisor:v0.49.1` image**
before recreating the paperless webserver — which is the only thing that prevented
a paperless **downgrade** (2.18.4 → 2.14.7), which would have corrupted the
paperless DB (schema downgrades are unsupported). It still left paperless-db and
paperless-broker stopped, so paperless was briefly down.

### Recovery + fix

- Edited host `/srv/apps/docker-compose.yml` to pin those four images back to
  `latest` and `docker compose up -d --pull never` to restore the stack.
- Set the four version vars in `roles/paperless_lxc/defaults/main.yml` to `latest`
  to match deployed reality (chosen over re-pinning). `make paperless TAGS=docker`
  is now idempotent — compose and `.env` render `ok`, handler does not fire.

## Follow-ups

- The old password is in public git history — rotation done, but consider it
  permanently leaked (mitigated: it's an internal docker-network-only credential).
- Version vars now track `latest`, losing reproducibility. Re-pin to explicit,
  host-verified versions later if desired — never below the running paperless.
- Two `make ... --check` failures (`share_drive_probe` .prom absent,
  `shell_environment` Node.js assert) are pre-existing check-mode artifacts,
  unrelated to this change.
