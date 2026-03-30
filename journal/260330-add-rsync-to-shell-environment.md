# Add rsync to shell environment CLI tools

Added `rsync` to the default CLI tools list in the `shell_environment` role
(`roles/shell_environment/defaults/main.yml`). This ensures all VMs and LXCs
that use the role have rsync available.

TrueNAS (`nas_vm`) is unaffected — it does not use the `shell_environment` role.
