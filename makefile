# Makefile - Ansible shortcuts for home server setup

# Set defaults
VAULT ?= --ask-vault-pass
PLAYBOOK_DIR := playbooks
ANSIBLE := .venv/bin/ansible-playbook
INVENTORY := -i inventory.ini

# Declare all available commands as .PHONY (always run)
.PHONY: all site proxmox truenas cloud_image media media_provision media_configure cloudflared help

all: site

site:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/site.yml $(VAULT)

proxmox:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/proxmox.yml $(VAULT)

truenas:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/truenas.yml $(VAULT)

cloud_image:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/cloud_image.yml $(VAULT)

media:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml $(VAULT)

media_provision:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml --tags media_provision $(VAULT)

media_configure:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/media_vm.yml --tags media_configure $(VAULT)

cloudflared:
	$(ANSIBLE) $(INVENTORY) $(PLAYBOOK_DIR)/cloudflared.yml $(VAULT)

help:
	@echo ""
	@echo "🚀 Available make commands:"
	@echo ""
	@echo "  make site             → Run full home server setup"
	@echo "  make proxmox          → Provision Proxmox base services"
	@echo "  make truenas          → Setup TrueNAS VM"
	@echo "  make cloud_image      → Upload Ubuntu cloud image"
	@echo "  make media            → Full Media VM provisioning and config"
	@echo "  make media_provision  → Only provision Media VM"
	@echo "  make media_configure  → Only configure Media VM (Docker, services)"
	@echo "  make cloudflared      → Provision and configure Cloudflared LXC"
	@echo "  make help             → Show this message"
	@echo ""
