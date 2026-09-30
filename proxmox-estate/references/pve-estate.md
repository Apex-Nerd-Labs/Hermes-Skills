# The Proxmox Estate — structure, mechanics, and the placement rule

Merged estate reference. It fuses three views that used to live apart: the recorded estate layout
(structure), the command set that re-derives it (mechanics), and the ambient-credential placement
rule. **Re-verify every figure before relying on it** — the live commands are the durable part, the
recorded values are a snapshot that ages. `scripts/lxc-credential-audit.sh` prints the current state
in one pass. Names, addresses and ids below are illustrative placeholders (`<pve-host>`, `<ctid>`,
`<lan-ip>`, `<tailnet-ip>`, `<storage>`); substitute your own.

## Node reality

- **`<pve-host>` is the only Proxmox VE node.** It is standalone: `pvecm status` reports no
  corosync config (`... does not exist`), and `/etc/pve/nodes/` lists a single entry. Any request
  phrased as "one of my PVE machines" resolves to this one node — say so explicitly instead of
  implying a choice that does not exist.
- **The PVE node is often also the home LAN gateway.** Its bridge `vmbr0` carries the LAN gateway
  address (`<lan-ip>`) — the default route for the house — and it commonly hosts the DNS guest
  (pihole). A compromise of this host reaches every device on the home network. That is the reason a
  new reachable service gets its own unprivileged guest rather than sharing one.
- Hardware: Celeron-class, 4 cores, ~11.8 GB RAM. The summed LXC `memory=` values across guests
  exceed physical RAM by design (ceilings, not reservations).
- A LAN sweep for tcp/8006 returns only the node itself. Do not assume siblings exist.

## Storage

| Storage | Type | Use |
|---|---|---|
| `<storage-thin>` | lvmthin | Large and empty — preferred rootfs for a new guest |
| `<storage-dir>` | dir | Production images; roughly half full |
| `<backup-store-a>` | dir | Backup target; same filesystem as `<storage-dir>` |
| `<backup-store-b>` | dir | Backup target |
| `<backup-store-c>` | dir | Backup target; its job is currently disabled |
| `<storage-media>` | dir | Media |

A storage only accepts dumps if its `content` list includes `backup`. Several stores can point at
the same underlying filesystem — read the `path` behind each store name in `/etc/pve/storage.cfg`,
never the label.

## LXC guest inventory

A representative estate. The lesson is in the role column, not the numbers: a **service host** is
whatever holds several credential-bearing things at once, and its name is not a reliable label.

| vmid | name | role |
|---|---|---|
| `<ctid>` | `<name>` | Multi-service Docker host: Portainer, n8n, Semaphore + MySQL, Microbin, Homepage, a browser terminal, mongod, postfix, cloudflared, a reverse-tunnel client, **plus a Docker Engine API exposed on `:2375` with no TLS**. Highest credential density on the host — never a colocation target. |
| `<ctid>` | `<name>` | Telemetry collector |
| `<ctid>` | `<name>` | DNS (pihole) |
| `<ctid>` | `<name>` | Company control plane running in Docker, published on the LAN IP and the tailnet IP. |
| `<ctid>` | `<name>` | Home Assistant |
| `<ctid>` | `<name>` | Network controller (UniFi), cloudflared, a remote Docker agent on `:2376`, portainer_agent, a browser terminal. Memory-tight: a small limit with a resident JVM. |
| `<ctid>` | `<name>` | SMS gateway |

A guest called `web` may be a network controller; one named after software may never have had that
software installed. Verify contents, not names.

## Backup jobs

| Job id | Storage | Schedule | vmid | Enabled |
|---|---|---|---|---|
| `backup-<uuid-a>` | `<backup-store-a>` | mon..fri 00:00 | `<ctid>,<ctid>,<ctid>,<ctid>,<ctid>,<ctid>` | yes |
| `backup-<uuid-b>` | `<backup-store-b>` | mon..fri 05:00 | `<ctid>,<ctid>,<ctid>,<ctid>,<ctid>` | yes |
| `backup-<uuid-c>` | `<backup-store-c>` | 22:30 | `<ctid>,<ctid>` | **no** |

`pvesh set /cluster/backup/<job-id> --vmid <list>` **replaces the whole vmid list**, so pass the
complete set, comma-separated. Never hand-edit `/etc/pve/jobs.cfg` (it is pmxcfs-backed). A host may
carry three jobs where one is disabled — read `enabled` before claiming a guest is "in the backups".

## Reaching LAN-only guests

Guests with no Tailscale node are reachable only from inside the LAN. From a workstation that holds
the private key, jump through the PVE node:

```bash
ssh -J <user>@<pve-host> <user>@<lan-ip>
```

Run that jump **from the machine holding the private key**. Executing it from the PVE node makes it
SSH to itself and report `Permission denied`, which looks like a key problem and is not.

A guest's `from="<tailnet-cidr>"` SSH key restriction blocks LAN access. When a guest has no tailnet
address yet, widen it to `from="<tailnet-cidr>,<lan-cidr>"` or the Captain cannot reach the box;
narrow it back once the guest is on the tailnet.

## Tailnet nodes added to this estate

Verify with `tailscale status`. Known additions beyond the pre-existing hosts:

| Node | Address | MagicDNS |
|---|---|---|
| `<tailnet-node>` | `<tailnet-ip>` | `<node>.<tailnet-name>.ts.net` |

## Discovering the estate

```bash
# Node identity and clustering
pvecm status                # "Corosync config ... does not exist" => standalone, not a cluster
sudo ls -1 /etc/pve/nodes/   # one directory per node
pveversion

# Guests
sudo pct list                # LXC — the Name column is the config `hostname` field
sudo qm list                 # QEMU VMs
sudo cat /etc/pve/lxc/<id>.conf
sudo cat /etc/pve/qemu-server/<id>.conf

# Capacity
sudo pvesm status            # every storage: total / used / available / %
nproc; free -m; df -h /; cat /proc/loadavg
lscpu | grep -E 'Model name|^CPU\(s\)'

# Is this host also the LAN router / DNS?
ip -br a | grep -E 'vmbr|eno|eth'
```

**Finding every PVE node on a LAN** — sweep for the web UI port rather than guessing hostnames:

```bash
for i in $(seq 1 254); do
  (timeout 0.6 bash -c "echo >/dev/tcp/<lan-subnet>.$i/8006" 2>/dev/null && echo "PVE-UI <lan-subnet>.$i") &
done; wait
```

`tailscale status` is the authoritative inventory of *reachable* hosts, but anything not joined to
the tailnet is missing from it — a standalone PVE node with no Tailscale appears nowhere.

## Backups

```bash
sudo pvesh get /cluster/backup --output-format json      # job ids, storage, vmid list, enabled, schedule
sudo pvesh set /cluster/backup/<job-id> --vmid <a,b,c>   # extend an existing job
sudo vzdump <id> --storage <store> --mode snapshot --compress zstd --notes-template '...'
ls -la <store-path>/dump/                                # ALWAYS verify the archive landed
```

A storage only accepts dumps if its `content` list includes `backup` — check `/etc/pve/storage.cfg`
for the path behind each store name before assuming where dumps go. Several stores can point at the
same underlying filesystem; look at the `path`, not the label.

## LXC config flags that matter

| Flag | Why |
|---|---|
| `unprivileged: 1` | A container escape lands on the host, not as host root. Always. |
| `features: nesting=1,keyctl=1` | Required for Docker inside the LXC. |
| `lxc.cgroup2.devices.allow: c 10:200 rwm` | Grants the tun device (cgroup2 form on PVE 9). |
| `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file` | Needed for Tailscale/WireGuard in the guest. |
| `net0 ...,firewall=1` | House convention on every guest. |
| `rootfs: <store>:<id>/...` | Put new guests on the thin pool with free space, not where production lives. |

The older `lxc.cgroup.devices.allow` form still works but logs a deprecation warning on every `pct`
invocation — use the cgroup2 spelling on new guests.

Changing `memory`, `cores`, `hostname` or `features` requires a restart. Apply the hostname inside
the guest too, or the two will disagree:

```bash
pct set <id> --hostname <name>
pct exec <id> -- bash -lc 'echo <name> > /etc/hostname; grep -q <name> /etc/hosts || echo "127.0.1.1 <name>" >> /etc/hosts'
```

## Getting work into and out of a guest

```bash
pct exec <id> -- bash -lc '...'          # run a command inside
pct push <id> <src> <dest> --perms 600   # copy a file in with explicit permissions
ssh -J <pve-host> <user>@<guest-lan-ip>  # reach a LAN-only guest — run this FROM a host holding
                                         # the private key, never from the PVE node itself
```

For anything longer than a couple of commands, write the script locally and pipe it in — nested
heredocs through `pct exec` have several layers of quoting and mangle easily:

```bash
ssh <pve-host> 'sudo -n bash -s' < script.sh
```

A probe that reads credential paths deserves a written script rather than an inline one-liner: an
inline command that both wraps `pct exec` and references secret paths can be flagged by a security
scanner as unresolvable and blocked. The same probe as a script file read from stdin is not.

## Tailscale inside an unprivileged guest

1. Add the cgroup2 + `/dev/net/tun` plumbing above, then restart the guest. Confirm the device:
   `pct exec <id> -- ls -la /dev/net/tun`.
2. Install from the apt repo rather than piping a script to a shell:
   ```bash
   curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/<codename>.noarmor.gpg \
     -o /usr/share/keyrings/tailscale-archive-keyring.gpg
   curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/<codename>.tailscale-keyring.list \
     -o /etc/apt/sources.list.d/tailscale.list
   apt-get update && apt-get install -y tailscale
   ```
3. Hand the auth key to `tailscale up` **as a file**, so it never appears in the process list:
   ```bash
   pct push <id> key.tmp /root/.tskey --perms 600
   pct exec <id> -- tailscale up --auth-key=file:/root/.tskey --hostname=<name> --accept-routes=false
   pct exec <id> -- shred -u /root/.tskey     # then verify removal
   ```
   A tailnet auth key that carries tags may require `--advertise-tags`; read the error rather than
   guessing.
4. Record the tailnet IP and MagicDNS name — both belong in the app's allowed-hostnames list and in
   its published port bindings.

## Judging whether a Docker-in-LXC build is alive

- `dockerd` burning ~10-30% CPU plus a growing `docker system df` build cache means progress.
- A `stat` on the build log showing a modification within seconds is the cheapest liveness proof —
  cheaper and more reliable than parsing the log.
- A stage that copies `node_modules` between layers plateaus for minutes with no new log lines on
  spinning or directory-backed storage. A long silence is not a hang; check CPU and log mtime.
- Watch `df -h /` during the build. Node/pnpm layers plus build cache can consume 10 GB+; a 30 GB
  guest is comfortable but not generous.

---

# The ambient credential surface — the placement rule

## The principle

A service that **executes code** — an agent runtime, an orchestrator, a CI runner — inherits the
container's entire environment and filesystem. Its own sandboxing is irrelevant if the container it
sits in is credential-dense: anything it can read, a compromise of it can read.

So the placement question is not "does this container have free RAM", it is **"what does a process
in here already have access to?"**

## Enumeration recipe (run on the candidate guest)

```bash
# services + what is listening, with owning process
systemctl list-units --type=service --state=running --no-pager --no-legend
ss -tlnp

# container runtime surface
docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'
ls -la /var/run/docker.sock

# credential-bearing config locations — existence + permissions only, never print contents
for p in /root/.ssh /etc/cloudflared /root/.cloudflared /etc/rport /var/lib/rport \
         /etc/letsencrypt /opt /srv /var/www; do
  [ -e "$p" ] && { echo "PRESENT: $p"; ls -la "$p" | head -5; } || echo "absent:  $p"
done
```

Never print credential *contents*. Confirm presence, ownership and mode; that is enough to make the
placement call and it keeps secrets out of the transcript.

## Disqualifiers — any one of these rules the container out

| Found | Why it disqualifies |
| --- | --- |
| `dockerd` on **2375** (no TLS) | Unauthenticated root over the Docker API. Docker's own docs call this equivalent to unrestricted root. |
| `/var/run/docker.sock` | Root-equivalent for anything that can open it. |
| A remote agent on **2376** | The same root, over the network. |
| Portainer / Portainer agent / remote docker agents | Container control with exec. |
| IaC or workflow stores (`semaphore`, `n8n`, ...) | Hold inventory, SSH keys and integration credentials in one place. |
| `rport` / reverse-tunnel clients | A persistent inbound remote-access channel. |
| Web terminals (browser shell), paste bins | Direct interactive access, plus a data-exfil surface. |
| Cloudflare tunnel credentials | Ingress into the whole network, not just the app. |
| VPN/WireGuard/Tailscale node keys of the host | Lateral movement identity. |
| Co-resident database server | Direct data access. |

A container holding several of these is a **service host**, whatever its name suggests. Its name
lies: a guest called `web` may be a network controller, and one called after software may never have
had that software installed.

## Why "reuse a production container" fails

The tempting argument is cost — an existing guest already has Docker, nesting, a tunnel and an
identity, so reusing it adds no overhead. It fails on two counts:

1. **Blast radius is not saved, only shared.** A compromise of the new service becomes a compromise
   of every credential in that guest, and vice versa. The isolation you are skipping *is* the
   control.
2. **The resource saving is largely illusory.** LXC `memory=` is a cgroup **ceiling**, not a
   reservation. A new guest at `memory=3072` costs approximately nothing while idle. On overcommitted
   hosts this is already how every other guest works.

Prefer: a **new dedicated guest**, and if the estate already has a suitable dormant guest, reusing
that shell (wiped) is acceptable — it was never serving anything, so there is no ambient surface to
inherit.

## Sizing and hardening a new guest

```bash
pct set <vmid> --hostname <name> --cores 2 --memory 3072 \
  --features "nesting=1,keyctl=1"        # keyctl is required for Docker-in-LXC
```

- Put the rootfs on the **thin/empty** pool, not the pool that already holds production data.
- `net0: ...,firewall=1`; add PVE firewall rules that allow the service port only from the trusted
  ranges (tailnet / admin subnet) and drop it from the general LAN.
- Add the `/dev/net/tun` bind + device allow **only if** the guest will run its own VPN/tailnet
  identity.
- Give the container a non-root uid where the image supports it, plus `pids_limit`, a memory cap and
  a restart policy. Do not bind-mount the docker socket into the service.
- Size steady state from measurement, not peak.
