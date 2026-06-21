# 260621 — Sync paperless_lxc compose template to live host + fix directory-ownership tasks

## Context

The `docker-compose.yml` running on the `paperless` LXC had drifted ahead of the
Ansible template (`roles/paperless_lxc/templates/docker-compose.yml.j2`). The
drift came from the Library "Ask"/semantic-search rollout, which had been applied
by hand on the host but never folded back into the role. A deploy from the
then-current template would have *reverted* the live host and broken semantic
search.

## What drifted (and was reconciled into the template)

1. **`library-db` image** — host runs `pgvector/pgvector:pg17` (for the
   `document_chunks` embeddings); template still had plain
   `docker.io/library/postgres:17`. A deploy would have downgraded it and broken
   the `vector` type. Template updated to `pgvector/pgvector:pg17`.
2. **`library-embedder` service** — an entire new service (bge-m3 via
   `ghcr.io/huggingface/text-embeddings-inference:cpu-1.7`, `mem_limit: 6g`,
   `--max-batch-tokens 2048`, `embedder-cache` volume) existed on the host but not
   in the template. Added.
3. **Embedding/Ask env + deps** — `LIBRARY_EMBEDDING_SERVICE_URL`,
   `LIBRARY_ANTHROPIC_API_KEY`, and a `depends_on: library-embedder` on both
   `library-webserver` and `library-worker`. Added.
4. **API key handling** — the host had the Anthropic key *hardcoded in plaintext*
   in the compose file. In the template it's routed through
   `{{ vault_library_anthropic_api_key }}` (and added to `.env.j2`), so no secret
   lands in git.

## Directory-ownership task fix (the more important change)

While reviewing a `--check --diff` run, the `Create base app directories` task
(tag `docker`) was found to force **every** data dir to `root:root 0755` —
including the Postgres data dirs, which must be `0700` and owned by the in-image
postgres uid (999). The corrective `Ensure correct directory ownership` task only
carried the `paperless` tag, so on a `--tags docker` deploy it was skipped, leaving
the dirs clobbered until the container entrypoints happened to re-chown on restart.
That task was also buggy: it set `/data` to `999:999 0700` (should be the paperless
app uid `1001` / `0755`) and never touched `library/pgdata` at all.

Reworked into two idempotent tasks, both tagged `[docker, paperless]` so no tag
combination can leave the dirs wrong:

- **Config dirs** (`alloy`, `promtail`) → `root:root 0755`.
- **Data dirs**, each with the ownership the container actually uses, matching the
  live host so the diff is a no-op:
  - `paperless/data` → `{{ puid }}:{{ pgid }}` (1001) `0755`
  - `paperless/pgdata` → `999` / `0700`
  - `library/pgdata` → `999` / `0700`  (previously uncovered)
  - `paperless/redisdata` → `999` / `0755`

Deleted the old `Ensure correct directory ownership` task. Also cleaned up the
malformed `loop` on the `Upload config files` (alloy) task — the `- alloy:` item
was producing a dead `{alloy: null, ...}` key.

Note: `guid` is *not* a typo for `pgid` — it's a repo-wide var (`group_vars/all`,
`= 1001`) used across many roles.

## Deploy + verification

Ran `make paperless skip=nviv tags=docker`. The directory tasks reported `ok`
(no churn — the fix works); `.env` and `docker-compose.yml` updated; handlers
restarted the stack. Verified after restart:

- All containers up; `library-db`, `library-webserver`, `paperless-db/broker`
  healthy; `library-embedder`/`library-worker` running.
- `.env` contains `LIBRARY_ANTHROPIC_API_KEY`.
- Dir ownership held: `pgdata` dirs `999:0 0700`, `data` `1001:1001 0755`,
  `redisdata` `999:0 0755`.

## Follow-up

- **Rotate the Anthropic API key.** It was exposed in plaintext on the host's old
  compose file (and in deploy/dry-run terminal output) before being moved to vault.
  Rotate, update `vault_library_anthropic_api_key`, and re-run the deploy.
