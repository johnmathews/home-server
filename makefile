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
.PHONY: all site nas cloud_image media help


all: site

site:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml $(VAULT) $(ANSIBLE_OPTS)

pve:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/pve.yml $(VAULT) $(ANSIBLE_OPTS)

nas:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/nas.yml $(VAULT) $(ANSIBLE_OPTS)

mail:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/mail_vm.yml $(VAULT) $(ANSIBLE_OPTS)

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

tube:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/tubearchivist_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

prometheus:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/prometheus_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

paperless:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/paperless_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

media-dl:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_dl_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

music:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/music_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

jelly:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/jellyfin_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

open-webui:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/open_webui_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

cloudflared:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/cloudflared_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

agent:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/agent_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

dev:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/dev_lxc.yml $(VAULT) $(ANSIBLE_OPTS)

atuin:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/atuin.yml $(VAULT) $(ANSIBLE_OPTS)

shell:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/shell_environment.yml $(VAULT) $(ANSIBLE_OPTS)

share_drive_probe:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/share_drive_probe.yml $(VAULT) $(ANSIBLE_OPTS)

tailscale:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/tailscale.yml $(VAULT) $(ANSIBLE_OPTS)

lint-paths:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/validate-paths.yml $(VAULT) $(ANSIBLE_OPTS)

requirements:
	.venv/bin/ansible-galaxy role install -r requirements.yml -p ~/.ansible/roles && .venv/bin/ansible-galaxy collection install -r requirements.yml && uv pip install -r requirements.txt

# ───────────── Quality Checks ─────────────
check:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml --check $(VAULT)

lint:
	.venv/bin/ansible-lint $(PLAYBOOK_DIR) roles/

clean:
	rm -f *.retry
	rm -f .ansible.log

ci: lint check

# ───────────── Help Message ───────────────
help:
	@echo ""
	@echo "IMPORTANT: Run 'make requirements' first to install Ansible dependencies!"
	@echo ""
	@echo "Available make commands:"
	@echo ""
	@echo "  make requirements     → Install Ansible roles and collections (RUN THIS FIRST!)"
	@echo ""
	@echo "  make site             → Run full home server setup"
	@echo "  make pve              → Setup the proxmox node, doesnt setup authentication"
	@echo "  make nas              → Setup TrueNAS VM by provisioning a VM and uploading a TrueNAS ISO"
	@echo "  make media            → Full Media VM config"
	@echo "  make infra            → Full Infra VM config"
	@echo "  make key              → Build key server"
	@echo "  make traefik          → Traefik reverse proxy config"
	@echo ""
	@echo "  make check            → Dry run (no changes applied)"
	@echo "  make lint             → Lint playbooks and roles"
	@echo "  make ci               → Run lint + dry run (ideal for pre-commit or CI)"
	@echo "  make clean            → Remove temp files and retry logs"
	@echo "  make help             → Show this message"
	@echo ""
