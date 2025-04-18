# Makefile - Ansible shortcuts for home server setup

# Set defaults
VAULT ?= --ask-vault-pass
PLAYBOOK_DIR := playbooks
ANSIBLE := .venv/bin/ansible-playbook
INVENTORY := -i inventory.ini

# Declare all available commands as .PHONY (always run)
.PHONY: all site proxmox truenas cloud_image media media_provision media_configure cloudflared help homeassistant

all: site

site:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml $(VAULT)

proxmox:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/proxmox.yml $(VAULT)

truenas:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/truenas.yml $(VAULT)

homeassistant:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/homeassistant.yml $(VAULT)

media:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml $(VAULT)

media-provision:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml --tags media_provision $(VAULT)

media-configure:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml --tags media_configure $(VAULT)

cloudflared:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/cloudflared.yml $(VAULT)

requirements:
	.venv/bin/ansible-galaxy install -r requirements.yml

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
	@echo "🚀 Available make commands:"
	@echo ""
	@echo "  make site             → Run full home server setup"
	@echo "  make proxmox          → Provision Proxmox base services"
	@echo "  make truenas          → Setup TrueNAS VM by provisioning a VM and uploading a TrueNAS ISO"
	@echo "  make media            → Full Media VM provisioning and config"
	@echo "  make media-provision  → Only provision Media VM"
	@echo "  make media-configure  → Only configure Media VM (Docker, services)"
	@echo "  make check            → Dry run (no changes applied)"
	@echo "  make lint             → Lint playbooks and roles"
	@echo "  make clean            → Remove temp files and retry logs"
	@echo "  make ci               → Run lint + dry run (ideal for pre-commit or CI)"
	@echo "  make requirements     → Install ansible-galaxy roles"
	@echo "  make help             → Show this message"
	@echo ""
