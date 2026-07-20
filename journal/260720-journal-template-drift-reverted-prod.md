# media_vm journal templates had drifted behind the app — `make media` was reverting prod

**Date:** 2026-07-20

## What happened

The journal app (`journal-server`) shipped two changes that live in
host-mounted/interpolated files the `media_vm` role owns, but the role's
templates were never updated to match. So `make media tags=journal` silently
**reverted prod** to the stale template state on each run:

1. **`FITNESS_CREDENTIAL_KEY` was missing from the compose template.** The
   Fernet key that enables Garmin saved-credentials / unattended re-login was
   already rendered into `/srv/media/.env` (via `vault_fitness_credential_key`
   in `.env.j2`), but `roles/media_vm/templates/docker-compose.yml.j2` had no
   `- FITNESS_CREDENTIAL_KEY=${FITNESS_CREDENTIAL_KEY}` line in the
   `journal-server` `environment:` block. Compose's root `.env` is only used for
   `${VAR}` interpolation — not injected into containers — so the key never
   reached the container and the feature ran dark (`printenv` empty inside
   `journal-server`).

2. **`mood-dimensions.toml` was the old 2026-05-05 7-facet version.** The app
   had moved to a 2026-07-15 10-facet schema (physical/mental fatigue + vigor +
   tension split) and prod's DB already held 101 entries scored on the new
   facets — but the templated host file
   (`roles/media_vm/templates/journal/moods/mood-dimensions.toml`, mounted
   read-only over the image) still shadowed it with the old facets. `confirmed`
   by reading the live file and the DB facet names after a `make` run.

## Fix

Updated both templates to match the app's canonical state (compose env line
added; mood-dimensions.toml synced to `server/config/mood-dimensions.toml`),
committed, and re-ran `make media tags=journal`. Verified on prod: key present
in the container, mood-dimensions back to 2026-07-15/10-facet, container clean
(`restarts=0`). A second `make` run confirmed idempotency.

## Root cause (confirmed)

The `/srv/media` config files are Ansible-managed, but app-side config changes
weren't mirrored into the role's templates. Editing the files directly on the VM
is futile — the next `make` run overwrites them from the templates. The template
is the source of truth; app config changes must be mirrored here.

## What is deliberately not done

- No automated drift-detection between the app repo's canonical config
  (`server/config/mood-dimensions.toml`, `deploy/docker-compose.prod.yml`) and
  these templates. That would prevent recurrence but is a larger change; for now
  the runbook note (mirror app config → template → `make`) is the guard.
