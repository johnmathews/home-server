# Makefile - Ansible shortcuts for home server setup

# Set defaults

# VAULT ?= --ask-vault-pass
VAULT ?= --vault-password-file=.vault_pass.txt

PLAYBOOK_DIR := playbooks
ANSIBLE := .venv/bin/ansible-playbook
INVENTORY := -i inventory.ini

# Declare all available commands as .PHONY (always run)
.PHONY: all site truenas cloud_image media help

all: site

site:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml $(VAULT) $(TAGS)

proxmox:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/proxmox_node.yml $(VAULT) $(TAGS)

nas:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/truenas.yml $(VAULT) $(TAGS)

media:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml $(VAULT) $(TAGS)

infra:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/infra_vm.yml $(VAULT) $(TAGS)

key:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/key_server.yml $(VAULT) $(TAGS)

traefik:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/traefik_lxc.yml $(VAULT) $(TAGS)

lint-paths:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/validate-paths.yml $(VAULT) $(TAGS)

requirements:
	.venv/bin/ansible-galaxy install -r requirements.yml && uv pip install -r requirements.txt

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
	@echo "Available make commands:"
	@echo ""
	@echo "  make site             → Run full home server setup"
	@echo "  make proxmox          → Setup the proxmox node, doesnt setup authentication"
	@echo "  make nas              → Setup TrueNAS VM by provisioning a VM and uploading a TrueNAS ISO"
	@echo "  make media            → Full Media VM config"
	@echo "  make infra            → Full Infra VM config"
	@echo "  make key              → Build key server"
	@echo "  make traefik          → Traefik reverse proxy config"
	@echo "  make check            → Dry run (no changes applied)"
	@echo "  make lint             → Lint playbooks and roles"
	@echo "  make clean            → Remove temp files and retry logs"
	@echo "  make ci               → Run lint + dry run (ideal for pre-commit or CI)"
	@echo "  make requirements     → Install ansible-galaxy roles"
	@echo "  make help             → Show this message"
	@echo ""
