#!/usr/bin/env bash
set -euo pipefail

echo "Dell iDRAC Service Module install for Proxmox 9 (Debian 13 / trixie)"
read -rp "Proceed? (yes/no) " yn
[[ "${yn}" == "yes" ]] || { echo "Exiting..."; exit 0; }

# 1) Dell OpenManage GPG key -> dedicated keyring
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://linux.dell.com/repo/pgp_pubkeys/0x1285491434D8786F.asc \
  | gpg --dearmor | tee /usr/share/keyrings/dell-openmanage.gpg >/dev/null

# 2) Deb822 source for iSM (Dell only publishes iSM 5.4 on bullseye channel today)
#    Deb822 fields: Types, URIs, Suites, Components, Signed-By, Architectures, Enabled
cat >/etc/apt/sources.list.d/dell-ism.sources <<'EOF'
Types: deb
URIs: http://linux.dell.com/repo/community/openmanage/iSM/5400/bullseye
Suites: bullseye
Components: main
Signed-By: /usr/share/keyrings/dell-openmanage.gpg
Architectures: amd64
Enabled: yes
EOF

# 3) Pin to only allow iSM packages from linux.dell.com
cat >/etc/apt/preferences.d/dell-ism <<'EOF'
Package: dcism dcism-osc
Pin: origin "linux.dell.com"
Pin-Priority: 700

Package: *
Pin: origin "linux.dell.com"
Pin-Priority: -1
EOF

# 4) Install iSM (OS Collector first, then iSM)
apt update
apt install -y dcism-osc dcism

# 5) Enable + start
systemctl enable --now dcismeng

echo
systemctl --no-pager status dcismeng || true
dpkg -l | grep -E 'dcism|dcism-osc' || true
echo
echo "Done. In iDRAC9, check Overview -> OS info / iSM status."
echo "Logs: journalctl -u dcismeng -b"