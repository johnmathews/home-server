# 2026-08-22 — Scraping the document library's own application metrics

The library gained OpenTelemetry metrics for its Ask surface
([library#89](https://github.com/johnmathews/library/pull/89)) — token usage
split by cache kind, estimated cost, turn latency, tool-loop depth, errors by
category. Collecting them needed two changes here, because neither can live on
the host: `/srv/apps/.env` is templated by `document_library_lxc`, so a
hand-edit is reverted on the next run.

## What changed

1. `document_library_lxc/.env.j2` sets `LIBRARY_OTEL_METRICS_ENABLED=true`.
2. `prometheus_lxc` gains a `library` scrape job.

## Port 8010, not 8000

Worth recording because I got it wrong first and it is the obvious wrong guess.
The container listens on **8000** — that is the number in the library's own
docs, in its healthcheck, and in every `curl` you run *inside* the container.
Compose publishes it as **`8010:8000`**, so the host port, and therefore the
scrape target, is 8010.

Found by reading `document_library_lxc/templates/docker-compose.yml.j2` rather
than trusting the application's documentation, which is correct about the
container and silent about the mapping.

## Verified rather than assumed

Before applying:

- `curl` from prometheus_lxc (.115) to `192.168.2.117:8010/healthz` → **200**.
  Confirms reachability, so no firewall rule is needed. Doing this first meant
  the scrape job was never a guess.
- `/metrics` on that port → **404**, the expected pre-enable state, which also
  proves the *app* is what gates it rather than the network.
- Both templates still parse as Jinja2; the rendered `prometheus.yml` is valid
  YAML with 17 jobs including `library`.
- `promtool check config` on the rendered file, run inside the live Prometheus
  container → **SUCCESS**. YAML-validity is not Prometheus-validity, and this is
  the check that knows the difference.

After applying:

- `up{job="library"} => 1`, with `hostname="paperless"` applied by the relabel
  config — the full chain, not just the endpoint.
- First real turn produced `fresh=2`, `cache_write=62099`, `output=25`, and a
  cost metric matching `ask_turns.cost_usd` to six decimal places.

## The gap this exposed

**Nothing in CI validates a role or template change.** `.github/workflows/test.yml`
is path-filtered to `roles/sleep_hours/**` and `tests/**`, so this PR ran only
GitGuardian. `ansible-lint` exists as a `make lint` target but is not in CI —
and it currently fails on pre-existing `var-naming` warnings across several
roles, so wiring it up as-is would red every PR.

Concretely: a typo in `prometheus.yml.j2` would have been caught by nothing, and
would have taken monitoring down on the next `make prometheus`. It was caught
here only because I ran `promtool` by hand.

A CI job that renders every `*.j2` and runs `promtool check config` on the
Prometheus one would be cheap and would have caught it. Not done here — it is
its own change, and the ansible-lint baseline needs deciding first.

## What is deliberately not done

1. **Claude Code's CLI telemetry is not enabled.** It pushes over OTLP and this
   network has no collector — Prometheus scrapes, it does not receive. The
   `.env.j2` comment records what to set if one is ever added, and warns that
   the app refuses to start if any `OTEL_LOG_*` content variable is set, because
   those export prompt and tool content, which for Ask is document text.
2. **No dashboard, no alert rules.** `rules.yml.j2` is untouched. There is now
   data and nothing looking at it.
3. **No backfill.** Metrics start at zero from the first Ask after the role runs;
   the ~55 historical turns in `ask_turns` are not represented.
