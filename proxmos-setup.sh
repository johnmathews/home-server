#!/bin/bash

echo "🔧 Starting Proxmox Initial Configuration..."

# 1. Enable the Proxmox Community Repo
echo "📦 Configuring Proxmox Community Repository..."
sed -i 's/^# deb http:\/\/download.proxmox.com/deb http:\/\/download.proxmox.com/' /etc/apt/sources.list.d/pve-enterprise.list || true
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-sub.list

# 2. Update and Upgrade
echo "⬆️ Updating and upgrading system packages..."
apt update && apt -y dist-upgrade

# 3. Install Common Tools
echo "🛠️ Installing useful tools..."
apt install -y vim htop curl wget git zram-tools net-tools gnupg2

# 4. Enable and configure ZRAM (optional but recommended)
echo "💾 Setting up ZRAM swap..."
cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram
EOF
systemctl daemon-reexec
systemctl start systemd-zram-setup@zram0.service
systemctl enable systemd-zram-setup@zram0.service

# 5. Optional: configure email alerts
# echo "⚙️ Configuring email alerts..."
# Replace this with actual mail setup if desired

echo "✅ Done. You may want to reboot the node: 'reboot'"
