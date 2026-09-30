#!/bin/bash
# Ambient-credential audit for Proxmox LXC guests. READ-ONLY.
# Prints existence and permissions only -- never secret values.
#
# Run from an SSH-reachable PVE node (piped, to avoid nested-quoting breakage):
#   ssh <user>@<pve-host> 'sudo -n bash -s' < scripts/lxc-credential-audit.sh
#
# Answers one question: if a new service were placed in this guest, what would it
# inherit? Any guest showing a Docker socket or an ingress tunnel is a
# disqualifying colocation target.

set -u

echo "########## HOST ##########"
hostname
pveversion 2>/dev/null | head -1
echo "--- memory (MiB) ---"
free -m | head -2
echo "--- storage ---"
pvesm status 2>/dev/null

echo
echo "########## GUESTS ##########"
pct list 2>/dev/null

for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
  echo
echo "===================== vmid ${id} ====================="
  pct config "${id}" 2>/dev/null | grep -E '^(hostname|cores|memory|swap|rootfs|unprivileged|features|net0|onboot)' | sed 's/^/  /'
  st=$(pct status "${id}" 2>/dev/null | awk '{print $2}')
  echo "  status: ${st}"
  if [ "${st}" != "running" ]; then
    echo "  (stopped -- config inspected only)"
    continue
  fi
  pct exec "${id}" -- bash -lc '
    echo "  -- credential surface (existence + perms only) --"
    for p in /var/run/docker.sock /root/.ssh /home/*/.ssh /etc/rport /var/lib/rport \
             /etc/cloudflared /root/.cloudflared /etc/letsencrypt /var/lib/docker \
             /opt /etc/sudoers.d; do
      if [ -e "$p" ]; then
        echo "     PRESENT  $p  [$(stat -c "%a %U:%G" "$p" 2>/dev/null)]"
      fi
    done
    echo "  -- listening sockets --"
    ss -tlnH 2>/dev/null | head -25 | sed "s/^/     /"
    echo "  -- docker --"
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --format "     {{.Names}} | {{.Image}} | {{.Status}}" 2>/dev/null
    else
      echo "     no docker installed"
    fi
  ' 2>/dev/null
done

echo
echo "########## BACKUP JOBS ##########"
pvesh get /cluster/backup --output-format json 2>/dev/null
echo
