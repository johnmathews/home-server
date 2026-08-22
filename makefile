# Makefile - Ansible shortcuts for home server setup

# Set defaults

# VAULT ?= --ask-vault-pass
VAULT ?= --vault-password-file=.vault_pass.txt

PLAYBOOK_DIR := playbooks
ANSIBLE := .venv/bin/ansible-playbook

INVENTORY := -i inventory.ini
# INVENTORY := -i inventory-tailscale.ini


# Pass like: make media TAGS=homepage
# Also supported:
#   make media SKIP=bigstuff
#   make media LIMIT=infra
#   make media EXTRA="--diff -vv"
TAGS  ?=
SKIP  ?=
LIMIT ?=
EXTRA ?=

tags  ?=
skip  ?=
limit ?=

t     ?=          # TAGS shorthand: make media t=homepage
s     ?=          # SKIP shorthand: make media s=heavy
l     ?=          # LIMIT shorthand: make media l=infra

# Fold aliases into the canonical vars (uppercase wins if set)
TAGS  := $(or $(strip $(TAGS)),$(strip $(tags)),$(strip $(t)))
SKIP  := $(or $(strip $(SKIP)),$(strip $(skip)),$(strip $(s)))
LIMIT := $(or $(strip $(LIMIT)),$(strip $(limit)),$(strip $(l)))

# Build ansible option string from simple vars
TAGS_ARG  := $(if $(strip $(TAGS)),--tags $(TAGS),)
SKIP_ARG  := $(if $(strip $(SKIP)),--skip-tags $(SKIP),)
LIMIT_ARG := $(if $(strip $(LIMIT)),--limit $(LIMIT),)

ANSIBLE_OPTS := $(TAGS_ARG) $(SKIP_ARG) $(LIMIT_ARG) $(EXTRA)

# Declare all available commands as .PHONY (always run)
.PHONY: all site pve nas media infra key traefik immich tube prometheus \
        document-library music jelly open-webui cloudflared agent \
        finances \
        shell nfs share_drive_probe tailscale requirements \
        jelly-upgrade immich-upgrade refresh-sidecars \
        check lint clean ci ci-offline help check-ports test


all: site

site:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml $(VAULT) $(ANSIBLE_OPTS)

pve:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/pve.yml $(VAULT) $(ANSIBLE_OPTS)

nas:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/nas.yml $(VAULT) $(ANSIBLE_OPTS)

media:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml $(VAULT) $(ANSIBLE_OPTS)

infra:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/infra_vm.yml $(VAULT) $(ANSIBLE_OPTS)

key:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/key_server.yml $(VAULT) $(ANSIBLE_OPTS)

traefik:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/traefik_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

immich:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/immich_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

# Pull the newest immich release images, recreate onto them, health-check.
# docker compose up (not ansible) is what recreates on image-only changes:
# the compose definition is unchanged, so recreate:auto sees nothing to do.
immich-upgrade:
	ssh immich 'docker pull ghcr.io/immich-app/immich-server:release && docker pull ghcr.io/immich-app/immich-machine-learning:release && docker pull alangrainger/immich-public-proxy:latest'
	ssh immich 'cd /srv/apps && docker compose up -d'
	@echo "waiting for immich to come up..."; sleep 40
	@curl -sf -o /dev/null http://192.168.2.113:2283/api/server/ping && curl -s http://192.168.2.113:2283/api/server/version | python3 -c 'import json,sys; d=json.load(sys.stdin); print("immich healthy, version: v%s.%s.%s" % (d["major"], d["minor"], d["patch"]))' 

tube:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/tubearchivist_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

prometheus:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/prometheus_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

document-library:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/document_library_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

music:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/music_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

finances:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/family_finances_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

jelly:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/jellyfin_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

# Pull the newest jellyfin base, rebuild the local yt-dlp image, recreate, health-check
jelly-upgrade:
	ssh jelly 'docker pull jellyfin/jellyfin:latest && cd /srv/apps && docker compose build jellyfin && docker compose up -d jellyfin'
	@echo "waiting for jellyfin to come up..."; sleep 25
	@curl -sf -o /dev/null http://192.168.2.110:8096/health && curl -s http://192.168.2.110:8096/System/Info/Public | python3 -c 'import json,sys; print("jellyfin healthy, version:", json.load(sys.stdin)["Version"])'

open-webui:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/open_webui_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

cloudflared:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/cloudflared_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

agent:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/agent_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

# Pull newest images for the observability sidecars (alloy, node-exporter,
# cadvisor) across every host that runs them, then recreate. Handlers use
# pull:never, so this is the bulk "apply" for sidecar :latest drift shown on
# the Image Freshness dashboard. Scope with LIMIT=host; pick services with
# EXTRA='-e {"sidecars":["alloy"]}'.
refresh-sidecars:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/refresh_sidecars.yml $(VAULT) $(ANSIBLE_OPTS)

shell:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/shell_environment.yml $(VAULT) $(ANSIBLE_OPTS)

share_drive_probe:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/share_drive_probe.yml $(VAULT) $(ANSIBLE_OPTS)

tailscale:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/tailscale.yml $(VAULT) $(ANSIBLE_OPTS)

nfs:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/nfs.yml $(VAULT) $(ANSIBLE_OPTS)

# --force on roles and --upgrade on collections are both required for the pins in
# requirements.yml to mean anything: ansible-galaxy skips anything already
# installed unless told otherwise, so without these a changed pin is a no-op and
# you get "whatever was installed first" rather than what the file asks for.
requirements:
	.venv/bin/ansible-galaxy role install -r requirements.yml -p ~/.ansible/roles --force && .venv/bin/ansible-galaxy collection install -r requirements.yml --upgrade && uv pip install -r requirements.txt

# ───────────── Quality Checks ─────────────
check:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml --check $(VAULT)

# No path arguments on purpose. Scoping to `playbooks/ roles/` excluded
# host_vars/, group_vars/, requirements.yml, .ansible-lint and .github/ -- which
# between them held 6 of the 21 failures, including one in .ansible-lint itself.
# Bare ansible-lint reads exclude_paths from .ansible-lint, so this lints exactly
# what CI lints.
lint:
	.venv/bin/ansible-lint

clean:
	rm -f *.retry
	rm -f .ansible.log

# Runs under the venv, not system python: the checker renders the templates with
# jinja2 and parses them with pyyaml, both of which come from requirements.txt.
check-ports:
	.venv/bin/python scripts/check-duplicate-ports.py

# Runs every suite in tests/. Until now nothing invoked pytest at all, and
# tests/run_tests.sh globbed integration/ only — so the python tests and the
# unit bats suite had never run, in CI or locally.
# Needs bats, docker, jq and curl for the integration suite.
test:
	python3 -m pytest tests/ -q
	bash tests/run_tests.sh

# Two composites, split by what they need to reach.
#
#   ci-offline  needs nothing but this checkout: no network, no SSH, no vault
#               password. This is what a GitHub runner can execute, and it is
#               what .github/workflows/lint.yml runs.
#   ci          adds `check`, a --check dry run of site.yml against the live
#               fleet. It needs SSH to every production host and the gitignored
#               .vault_pass.txt, so it is operator-only and cannot run in CI.
#
# The old single `ci: lint check-ports check` never reached its last two stages:
# `lint` exits 2 on any failure and make stops at the first failed prerequisite.
ci-offline: lint check-ports test

ci: ci-offline check

# ───────────── Help Message ───────────────
help:
	@echo ""
	@echo "IMPORTANT: Run 'make requirements' first to install Ansible dependencies!"
	@echo ""
	@echo "Every target maps to one playbook and one role:"
	@echo "  make <target> -> playbooks/<host>.yml -> roles/<host>/ -> host <host>"
	@echo "Flags on any provisioning target:"
	@echo "  TAGS=/t= run one tag   SKIP=/s= skip a tag   LIMIT=/l= one host   EXTRA=\"--check --diff\""
	@echo ""
	@echo "  make requirements     → Install Ansible roles, collections and python deps (RUN THIS FIRST!)"
	@echo ""
	@echo " Whole fleet"
	@echo "  make site             → Run full home server setup (all hosts)"
	@echo "  make all              → Alias for 'make site'"
	@echo ""
	@echo " Hosts"
	@echo "  make pve              → Proxmox node (does not set up authentication)"
	@echo "  make nas              → TrueNAS VM: provision the VM and upload the ISO"
	@echo "  make media            → Media VM (Sonarr, Radarr, qBittorrent, Mullvad)"
	@echo "  make infra            → Infra VM (Grafana, Loki, Homepage, Portainer, Atuin)"
	@echo "  make key              → Key server (TrueNAS dataset encryption keys)"
	@echo "  make traefik          → Traefik reverse proxy"
	@echo "  make immich           → Immich photo management LXC"
	@echo "  make jelly            → Jellyfin LXC"
	@echo "  make tube             → TubeArchivist LXC"
	@echo "  make music            → Navidrome music LXC"
	@echo "  make prometheus       → Prometheus LXC"
	@echo "  make document-library → Document library LXC (host: paperless)"
	@echo "  make open-webui       → Open WebUI LXC"
	@echo "  make cloudflared      → Cloudflare Tunnel LXC (syncs local config AND the CF API)"
	@echo "  make agent            → Agent LXC (NanoClaw)"
	@echo "  make finances         → Family finances LXC"
	@echo ""
	@echo " Cross-cutting roles (run against many hosts)"
	@echo "  make shell            → Shell environment: zsh, p10k, CLI tools"
	@echo "  make nfs              → NFS client mounts"
	@echo "  make share_drive_probe→ Share-drive health probe + its textfile metrics"
	@echo "  make tailscale        → Tailscale on all hosts"
	@echo ""
	@echo " Upgrades"
	@echo "  make jelly-upgrade    → Pull newest Jellyfin base, rebuild, recreate, health-check"
	@echo "  make immich-upgrade   → Pull newest Immich release images, redeploy, health-check"
	@echo "  make refresh-sidecars → Pull+recreate alloy/node-exporter/cadvisor on all sidecar hosts"
	@echo ""
	@echo " Quality checks"
	@echo "  make lint             → ansible-lint over the WHOLE repo. Exits non-zero on any failure."
	@echo "  make check-ports      → Render every compose template, fail on a duplicate host port"
	@echo "  make test             → pytest (tests/) + the bats suites (needs docker, bats, jq, curl)"
	@echo "  make ci-offline       → lint + check-ports + test. No network, no SSH, no vault. What CI runs."
	@echo "  make check            → --check dry run of site.yml against the LIVE fleet (needs SSH + vault)"
	@echo "  make ci               → ci-offline + check. Operator-only; cannot run on a CI runner."
	@echo ""
	@echo " Housekeeping"
	@echo "  make clean            → Remove temp files and retry logs"
	@echo "  make help             → Show this message"
	@echo ""
