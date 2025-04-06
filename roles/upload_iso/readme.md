# Upload_iso Role

This role ensures that a TrueNAS SCALE ISO image is available on the Proxmox
server for VM installation. It checks for the ISO in a local `iso-images/`
directory (relative to the playbook), selects the latest version if multiple
ISOs are present, and uploads it to the Proxmox ISO storage directory if not
already uploaded.

## Behavior

- Creates the `iso-images/` directory if it doesn't exist.
- Searches for files matching the pattern: `TrueNAS-SCALE-*.iso`.
- Fails gracefully if no matching ISO is found.
- Automatically selects the latest ISO (based on filename sorting).
- Uploads the selected ISO to Proxmox (`/var/lib/vz/template/iso/`) if it’s not
  already present.

## Usage

1. Download the desired TrueNAS SCALE ISO from the official website.
2. Place it in the `iso-images/` directory at the root of your Ansible project.
3. Run the playbook:

```bash
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```
