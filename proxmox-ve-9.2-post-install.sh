#!/usr/bin/env bash
# Proxmox VE 9.2 post-install helper (independent adaptation of tteck's idea)
# For an already installed Proxmox VE 9.2 host only.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run this as root.' >&2; exit 1; }
for cmd in whiptail pveversion python3 apt-get systemctl tar; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
PVE_VERSION=$(pveversion | sed -nE 's/^pve-manager\/([0-9]+\.[0-9]+).*/\1/p')
[[ "$PVE_VERSION" == '9.2' ]] || { echo "Requires Proxmox VE 9.2 (detected: ${PVE_VERSION:-unknown})." >&2; exit 1; }
[[ -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]] || { echo 'Proxmox archive keyring missing; stop and investigate.' >&2; exit 1; }

info() { printf '\n==> %s\n' "$*"; }
ask() { whiptail --backtitle 'Proxmox VE 9.2 Post-Install' --title "$1" --yesno "$2" 13 72; }
warn() { whiptail --backtitle 'Proxmox VE 9.2 Post-Install' --title 'Warning' --msgbox "$1" 13 72; }

# Apt source files should be backed up before any changes.
BACKUP="/root/pve92-apt-backup-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
BACKUP_ITEMS=(apt/sources.list.d)
[[ -f /etc/apt/sources.list ]] && BACKUP_ITEMS+=(apt/sources.list)
tar -czf "$BACKUP" -C /etc "${BACKUP_ITEMS[@]}"
info "APT source backup: $BACKUP"

# Deactivate entries for a specific repo before writing a single canonical definition.
# Works with legacy .list and new .sources files; unrelated repository entries are retained.
# A .sources stanza with multiple URI/component values is left alone rather than damaged.
deactivate_repo() {
  local kind="$1"
  python3 - "$kind" <<'PY'
import pathlib, re, sys
kind = sys.argv[1]
root = pathlib.Path('/etc/apt')
files = ([root / 'sources.list'] if (root / 'sources.list').exists() else [])
files += sorted((root / 'sources.list.d').glob('*.list'))
files += sorted((root / 'sources.list.d').glob('*.sources'))

def match(url):
    url = url.lower()
    if kind == 'pve':
        return bool(re.search(r'(?:enterprise\.proxmox\.com|download\.proxmox\.com)/debian/pve(?:/|$)', url))
    if kind == 'ceph':
        return bool(re.search(r'(?:enterprise\.proxmox\.com|download\.proxmox\.com)/debian/ceph-[^\s/]+', url))
    return False

for path in files:
    content = path.read_text()
    if path.suffix != '.sources':
        lines = content.splitlines(keepends=True)
        out = []
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith(('deb ', 'deb-src ')) and match(stripped):
                out.append('# Disabled by PVE 9.2 post-install: ' + line)
            else:
                out.append(line)
        new = ''.join(out)
    else:
        stanzas = re.split(r'(\n\s*\n)', content)
        out = []
        for chunk in stanzas:
            uri_lines = re.findall(r'^URIs:\s*(.*)$', chunk, flags=re.M|re.I)
            is_target = any(match(url) for val in uri_lines for url in val.split())
            if is_target and re.search(r'^Enabled:\s*yes\s*$', chunk, re.M|re.I):
                chunk = re.sub(r'^Enabled:\s*yes\s*$', 'Enabled: no', chunk, flags=re.M|re.I)
            elif is_target and not re.search(r'^Enabled:', chunk, re.M|re.I):
                chunk = 'Enabled: no\n' + chunk
            out.append(chunk)
        new = ''.join(out)
    if new != content:
        path.write_text(new)
PY
}

# No blind replacement of existing Debian mirrors, pinned sources, or components.
# Proxmox 9.2 already installs correct Debian sources by default.
if ask 'DEBIAN REPOSITORIES' 'Replace Debian sources with standard Debian 13 Trixie entries?\n\nChoose No if you have custom mirrors, pins, or repository configuration.'; then
  # Deactivate only standard Debian entries to avoid duplicate sources and Signed-By conflicts.
  python3 - <<'PY'
from pathlib import Path
import re
root = Path('/etc/apt')
paths = ([root/'sources.list'] if (root/'sources.list').exists() else [])
paths += list((root/'sources.list.d').glob('*.list'))
paths += list((root/'sources.list.d').glob('*.sources'))
for path in paths:
    original = path.read_text()
    if path.suffix == '.sources':
        chunks = re.split(r'(\n\s*\n)', original)
        out = []
        for chunk in chunks:
            uris = re.findall(r'^URIs:\s*(.+)$', chunk, re.M|re.I)
            is_debian = any(('deb.debian.org/debian' in val or 'security.debian.org/debian-security' in val) for val in uris)
            if is_debian:
                if re.search(r'^Enabled:', chunk, re.M|re.I):
                    chunk = re.sub(r'^Enabled:.*$', 'Enabled: no', chunk, flags=re.M|re.I)
                else:
                    chunk = 'Enabled: no\n' + chunk
            out.append(chunk)
        result = ''.join(out)
    else:
        result = ''.join(('# Disabled by PVE 9.2 post-install: ' + line) if re.match(r'^\s*deb(?:-src)?\s+.*(?:deb\.debian\.org/debian|security\.debian\.org/debian-security)', line) else line for line in original.splitlines(keepends=True))
    if result != original:
        path.write_text(result)
PY
  cat > /etc/apt/sources.list.d/debian-pve92.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  info 'Standard Debian 13 repositories configured.'
fi

if ask 'ENTERPRISE REPOSITORY' 'Disable the Proxmox Enterprise repository?\n\nRecommended if you do not have a paid subscription.'; then
  deactivate_repo pve
  info 'Existing Proxmox repository definitions deactivated (no-subscription can be added next).'
fi

if ask 'NO-SUBSCRIPTION REPOSITORY' 'Enable the Proxmox VE 9.2 no-subscription repository?'; then
  deactivate_repo pve
  cat > /etc/apt/sources.list.d/proxmox-pve92.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  info 'Proxmox no-subscription repository enabled.'
fi

if ask 'CEPH REPOSITORY' 'Configure Ceph Tentacle no-subscription repository?\n\nSelect No if you already run Ceph Squid or have a cluster: check its installed Ceph version first. Ceph repositories are not required on hosts that do not use Ceph.'; then
  if command -v ceph >/dev/null && ceph --version 2>/dev/null | grep -qE 'ceph version 19\.'; then
    warn 'Ceph Squid (19.x) detected. Leaving Ceph repositories unchanged to avoid an accidental major-version upgrade.'
  else
    deactivate_repo ceph
    cat > /etc/apt/sources.list.d/ceph-pve92.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-tentacle
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    info 'Ceph Tentacle no-subscription repository enabled.'
  fi
fi

if ask 'PVE TEST REPOSITORY' 'Add a disabled Proxmox test repository definition?'; then
  cat > /etc/apt/sources.list.d/pve-test-pve92.sources <<'EOF'
Enabled: no
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pvetest
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  info 'Disabled test repository definition added.'
fi

if ask 'SUBSCRIPTION NOTICE' 'Hide the web UI subscription reminder?\n\nThis is cosmetic and may be reverted by package updates.'; then
  warn 'For safety this script does not patch Proxmox JavaScript or add an APT post-install hook. Use a maintained 9.2-specific option if you want to modify the UI.'
fi

if ask 'HIGH AVAILABILITY' 'Disable HA services?\n\nONLY choose Yes for a standalone, non-clustered node. Clustered nodes must retain their cluster services.'; then
  if [[ -s /etc/pve/corosync.conf ]] || { command -v pvecm >/dev/null && pvecm status >/dev/null 2>&1; }; then
    warn 'Cluster configuration detected. No HA or Corosync services were changed.'
  else
    systemctl disable --now pve-ha-lrm.service pve-ha-crm.service || true
    info 'Standalone-node HA services disabled. Corosync was not changed.'
  fi
fi

info 'Checking package repositories ...'
if ! apt-get update; then
  echo "APT update failed. Inspect the errors. Original source configuration backup: $BACKUP" >&2
  exit 1
fi
info 'APT repository check completed successfully.'

if ask 'UPDATE PACKAGES' 'Upgrade installed Proxmox and Debian packages now?\n\nBack up VMs/containers before major upgrades.'; then
  apt-get dist-upgrade
  info 'Upgrade completed.'
fi

if ask 'REBOOT' 'Reboot the Proxmox host now?\n\nRunning VMs and containers will be interrupted.'; then
  reboot
else
  info 'Finished. Reboot when convenient.'
fi
