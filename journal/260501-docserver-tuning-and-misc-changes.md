# Docserver tuning, journal shadow transcription, and a Traefik migration plan

A small batch of in-flight changes shipped together. None are session work — this entry records what was committed
on 2026-05-01 alongside the shell_environment / journal-handler cleanup.

## infra_vm: docserver memory bump + chroma host fix

Three changes to `roles/infra_vm/templates/docker-compose.yml.j2` for the `documentation-server` container:

1. **Bug: chroma host name was wrong.** `DOCSERVER_CHROMA_HOST=chroma` — but the actual compose service name is
   `documentation-chroma`. Fixed to `DOCSERVER_CHROMA_HOST=documentation-chroma`. Without this, the docserver
   couldn't reach its vector store via Docker DNS.
2. **Memory: 512m/200m → 2g/1g.** The previous limit was tight for embeddings + indexing + Anthropic API workload.
   The companion `DOCSERVER_INGEST_MEM_LIMIT_MB=400` (an in-app self-cap) is removed; with the higher container
   limit it's no longer relevant.
3. **Chroma healthcheck cadence: 30s → 10s.** Faster failure detection for the dependency the server waits on.

`documentation/docserver.md` was materially out of date (claimed image `documentation-mcp-server`, container
`documentation-mcp-server`, memory 1536 MB — none of which matched reality). Refreshed to reflect the actual
3-container architecture (webapp / server / chroma), correct image and container names, current memory limits,
and the env vars the compose file actually uses.

## media_vm: shadow gemini transcription on journal-server

`roles/media_vm/templates/docker-compose.yml.j2` adds `TRANSCRIPTION_SHADOW_PROVIDER=gemini` to journal-server.
Primary transcription remains unchanged; gemini runs in shadow alongside it for comparison data. Measured-rollout
pattern — no behavior change for users until the shadow data justifies promotion.

## Journal context

Editorial cleanup of `roles/media_vm/templates/journal/context/things.md`:

1. Quoted proper nouns consistently ("Eefje De Visser", "Databricks", etc.).
2. Tightened phrasing on the `dataframe` entry.
3. Added Langchain entry under Engineering and a new Companies section (ABN AMRO).

New file `roles/media_vm/templates/journal/context/topics.md` — list of conversation topics the journal-server can
use as context. The earlier handler cleanup already wired the glob upload + restart, so this file ships
automatically on the next `make media t=journal`.

## Engineering team: Traefik migration plan

New planning doc `.engineering-team/traefik-migration-plan.md` — moves 5 portfolio-friendly services (Homepage,
Uptime, Speed, SRE, public Grafana dashboards on `stats.*`) from Cloudflare Zero Access to Traefik-proxied
routing with rate limiting. Adds path-restricted public Grafana, removes 4 unused duplicate subdomains.
Implementation deferred — this is the design only.
