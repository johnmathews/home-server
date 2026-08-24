# NanoClaw `.env` clobbered by Ansible — 27 h outage, role fixed

**Date:** 2026-08-24
**Host:** agent_lxc (192.168.2.107)
**Outcome:** live service restored 21:26 CEST; `.env` task, handler and template removed from `roles/agent_lxc`

## 1. Symptom

Every NanoClaw scheduled task (gmail-sweep, morning report, HN, FT, Dutch practice, weekly
reflection) and every inbound Slack message stalled from 2026-08-23 18:23 CEST. The host logged
`Waking container for due messages` every 60 s and 5,850 × `OneCLIRequestError ... api.onecli.sh
... StatusCode=401`; `docker ps` showed no agent container had started since the restart.

The working theory was that the last few days of repo tidy-up had changed the `.env` ownership
from `john` to `root`. That turned out to be wrong on both counts.

## 2. Root cause — three events, weeks apart

1. **The role always wrote `.env` as `root:root 0600`** — `roles/agent_lxc/tasks/main.yml`
   "Deploy nanoclaw .env file from template", unchanged since `cbf25d7` (2026-03-20). The recent
   tidy-up PRs touched only variable names in that file. The template `templates/.env.j2` was
   also frozen at 2026-03-20 — the v1 key set, with none of the v2 additions (`ONECLI_URL`,
   `SLACK_SIGNING_SECRET`, `TZ`, `HEALTH_PORT`, `JOURNAL_*`, `DOCS_MCP_URL`).
2. **A `make agent` on 2026-07-23 09:14 rendered that stale template over the live file.** The
   host journal shows the full role run; `.env` (837 B) and `/srv/apps/docker-compose.yml` share
   the timestamp, and `ssh agent-root` confirmed the live content was exactly the template's ten
   keys. The `Restart nanoclaw` handler then fired against unit `nanoclaw` — which does not exist
   (the real unit is `nanoclaw-583cc1c4`, suffix = `data/install-id`) — so the running process
   was never restarted and carried its good config in memory. Nothing visible broke.
3. **On 2026-08-23 18:22:57 the systemd watchdog killed the process (SIGABRT)** and restarted it
   14 s later. `src/env.ts` `readEnvFile` catches the `EACCES` and logs it at *debug* level, so
   the host came up with zero app env vars, the OneCLI SDK fell back to the cloud endpoint, and
   `container-runner.ts` refused to spawn without a gateway. Slack's adapter also needs
   `SLACK_SIGNING_SECRET`, which the template never had.

This is a repeat: NanoClaw's own `journal/260714-…env-restart-incident.md` and
`docs/operational-gotchas.md` item 35 record the identical clobber on 2026-07-12 and the manual
recovery on 07-14. The 07-23 Ansible run re-planted it nine days later; nobody connected
"`make agent`" with "`.env` gets truncated" because the effect is delayed until the next restart.

## 3. Live recovery (John, in a real terminal — sudo needs a password prompt)

```
sudo chown john:john /srv/apps/nanoclaw/.env
# appended ONECLI_URL=http://172.17.0.1:10254 and SLACK_SIGNING_SECRET=<from api.slack.com>
systemctl --user restart nanoclaw-583cc1c4
```

Verified after restart: `.env` is `john:john 0600` with both keys; 0 × `StatusCode=401` after the
21:26:18 log boundary; `Webhook server started port=3000 adapters=["slack"]`; containers for all
five groups spawned within a second (`nanoclaw-main-…`, three `nanoclaw-slack_…`, introspection);
recurrences being inserted again. Remaining warnings (`No active adapter for whatsapp`, `resend`
credentials missing) predate the incident and are out of scope.

`ONECLI_URL` came from `/srv/apps/nanoclaw/data/env/env` (May 2026 v2 reference copy, which
also matched the value in gotchas item 35); the OneCLI proxy at 172.17.0.1:10254 answered 200
throughout — nothing was wrong on that side.

## 4. Repo fix — Option A: Ansible stops touching `.env`

Chosen over "fix the template" (add the v2 keys, chown to john, correct the unit name) because a
template that has to track NanoClaw's `readEnvFile` key list will drift again, silently, with the
same delayed detonation. `documentation/agent.md` already said the role manages "infrastructure
around NanoClaw, not NanoClaw itself"; the `.env` task was the one exception, and it was wrong.

- `roles/agent_lxc/tasks/main.yml` — removed "Deploy nanoclaw .env file from template" (and with
  it the `nanoclaw` tag; `make agent t=nanoclaw` no longer does anything).
- `roles/agent_lxc/handlers/main.yml` — removed `Restart nanoclaw`.
- `roles/agent_lxc/templates/.env.j2` — deleted.
- `documentation/agent.md` — new section "NanoClaw `.env` is hand-managed" with the pre-restart
  check; role-manages list, paths list and tag list corrected. The doc stays on the freshness
  exempt list: only the Ansible/`.env` sections were re-verified today, and a stamp claims the
  whole doc was.

Vault variables that only this template referenced are now unreferenced but left in place
(`vault_claude_code_oauth_token`, `vault_assistant_has_own_number`, `vault_slack_app_token`,
`vault_slack_bot_user_oauth_token`, `vault_nanoclaw_openai_api_key`, `vault_parallel_api_key`,
`vault_github_token`). `vault_slack_bot_token` is still used by `roles/media_vm`. Pruning the
vault is a separate, deliberate change.

## 5. Not done / follow-ups

- gmail-sweep's `newer_than:2h` query self-heals a missed tick but not a 27 h gap; mail from
  2026-08-23 16:22 → 2026-08-24 21:26 UTC-ish needs one widened run if it matters.
- The watchdog SIGABRT itself (why the host missed a 30 s heartbeat) was not investigated; the
  restart merely exposed the landmine.
- `readEnvFile` swallowing `EACCES` at debug level is what made this silent. A WARN there (or a
  startup assert on required keys) belongs upstream in NanoClaw, not here.

## 6. Side investigation — bounces to `library@paperless.itsa-pizza.com`

John had been receiving "Delivery Status Notification (Delay)" mails for that address and asked
whether it is referenced anywhere in config or the vault. **It is not.** Searched: this repo
(roles, group_vars, host_vars, documentation — only the old `paperless.itsa-pizza.com` *hostname*
appears, in docs), both vault files decrypted (`vault_library_gmail_email_address` is the correct
library inbox alias), the library host `/srv/apps/.env` (`LIBRARY_EMAIL_USERNAME`
correct), and the agent host (`groups/`, `~/.nanobot`, `~/.config`, task files, memory).

The address exists only in the sweep agent's own records. On 2026-08-22 07:52 UTC the gmail-sweep
run (outcomes line 648, Revolut KYC reminder) called `mcp__gmail__send_email` with
`to: ["library@paperless.itsa-pizza.com"]` instead of the address `gmail-sweep.md:74` specifies —
a hallucination, most plausibly "library" fused with the `paperless.itsa-pizza.com` hostname from
a Cloudflare Access login-code mail it had skipped on 07-22. That host is Cloudflare-proxied web
only (no MX), so Gmail's SMTP attempts time out. Gmail's all-folders search confirms exactly one
message ever went to that address; the delay notices are retries of that one send and a final
permanent-failure bounce is due ~2026-08-25 08:00 UTC, after which it stops. When the sweep
processed the first bounce on 08-23 it rationalised it as an "auto-forward target" — its own
wrong guess, not a real Gmail rule.

Follow-ups (NanoClaw side, not this repo): re-forward Gmail thread `1a028755a3c6bea0` to
the library inbox alias (`vault_library_gmail_email_address`); add a hard "only permitted recipient" rule to
`groups/main/tasks/gmail-sweep.md`. Nothing to change here or in the vault.
