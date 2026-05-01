# Ansible Vault

## Overview

Sensitive data — API keys, passwords, tokens, certificates — is stored encrypted in `group_vars/all/vault.yml` using
**ansible-vault**. The vault is a single ~50 KB encrypted YAML file that lives in the repo. Plaintext values are never
committed.

The decryption key is in `.vault_pass.txt` in the repo root (mode `0600`, gitignored). Every `make` target that runs
Ansible passes `--vault-password-file=.vault_pass.txt` so secrets are decrypted in-memory at play time.

## Critical Recovery Note

**`.vault_pass.txt` is the single most important file in this repo.** If it is lost, the encrypted vault becomes
unrecoverable and every secret in it must be regenerated and rotated: ~50+ API keys, the SMB credentials, every service
password, the Proxmox API tokens, the WireGuard keys, etc. Back it up somewhere outside this machine — a password
manager, an offline drive, or a sealed envelope. Do not rely on this laptop's disk being the only copy.

## File Layout

```
.vault_pass.txt          mode 0600, gitignored — the decryption password
group_vars/all/vault.yml encrypted YAML, committed to git (the encrypted form is safe to commit)
group_vars/all/main.yml  plaintext defaults; references vault values via {{ vault_* }} vars
ansible.cfg              no vault config; password is passed via --vault-password-file
makefile                 every Ansible call has $(VAULT) = --vault-password-file=.vault_pass.txt
```

## What's in the Vault

Roughly 50 secrets, organised by service. Examples (names only — actual values are encrypted):

| Category        | Examples                                                             |
| --------------- | -------------------------------------------------------------------- |
| Proxmox         | `vault_proxmox_password`, `vault_proxmox_api_token_secret`           |
| TrueNAS / NAS   | `vault_truenas_password`, `vault_truenas_dataset_keys_json`          |
| SMB             | `vault_smb_username_password`, `vault_smb_media_vm_password`         |
| Media services  | `vault_sonarr_key`, `vault_radarr_key`, `vault_qbittorrent_password` |
| Monitoring      | `vault_grafana_password`, `vault_portainer_key`                      |
| Cloudflare      | `vault_cloudflared_account_id`, `vault_cloudflared_api_token`        |
| VPN / WireGuard | `vault_wireguard_private_key`, `vault_gluetun_password`              |
| Notifications   | `vault_pushover_user_key`, `vault_pushover_*_app_api_token`          |
| Tailscale       | `vault_tailscale_auth_key`                                           |
| Key server      | `vault_key_server_auth_token`                                        |
| Immich          | `vault_immich_db_password`, `vault_immich_key`                       |

The convention is `vault_<service>_<purpose>`. To see the full list:

```sh
ansible-vault view group_vars/all/vault.yml --vault-password-file=.vault_pass.txt | grep -E '^\w+:'
```

## Common Operations

### View the decrypted contents

```sh
ansible-vault view group_vars/all/vault.yml --vault-password-file=.vault_pass.txt
```

### Edit values

```sh
ansible-vault edit group_vars/all/vault.yml --vault-password-file=.vault_pass.txt
```

This decrypts the file into a temp location, opens `$EDITOR`, and re-encrypts on save.

### Add a new secret

1. Edit the vault and add `vault_my_new_secret: "value"` under the appropriate section.
2. Reference it from a template, default, or `.env.j2` as `{{ vault_my_new_secret }}` (or via an alias in
   `group_vars/all/main.yml`).
3. Run the relevant `make <target>` to deploy.

### Rotate the vault password

```sh
ansible-vault rekey group_vars/all/vault.yml --vault-password-file=.vault_pass.txt --new-vault-password-file=/tmp/newpass
mv /tmp/newpass .vault_pass.txt
chmod 0600 .vault_pass.txt
git commit -am "Rotate vault password"
```

Update the off-site backup of `.vault_pass.txt` immediately afterward.

## Conventions

1. **Vault names are prefixed `vault_`.** This makes it grep-able and obvious in templates that a value comes from the
   vault.
2. **Don't reference vault vars directly in templates.** Add a plaintext alias in `group_vars/all/main.yml` (e.g.
   `grafana_password: "{{ vault_grafana_password }}"`) and reference the alias. This keeps the vault list curated and
   makes refactoring easier.
3. **Encrypted file commits are safe.** Git diffs of `vault.yml` show ciphertext; merging conflicts on it requires manual
   resolution after `ansible-vault decrypt` / re-encrypt.

## Troubleshooting

- **`ERROR! Decryption failed (no vault secrets were found that could decrypt)`** — the password in `.vault_pass.txt`
  doesn't match what the vault was encrypted with. Either restore the correct password from your off-site backup or, if
  truly lost, delete the vault and recreate it by rotating every secret it contained.
- **`make` complains about a missing `vault_*` var** — usually means a new template references a variable you haven't
  added to the vault yet. Run `ansible-vault edit` and add it.
