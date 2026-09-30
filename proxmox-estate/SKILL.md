---
name: proxmox-estate
description: "Use when working on the Proxmox estate."
version: 1.0.0
author: Spock
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [proxmox, lxc, vm, deployment, hardening, backups, restore, security]
    related_skills: [paperclip-creator, ssh-immutable-authorized-keys, cron-monitor-watchdogs, fleet-skill-rollout]
---

# Working on the Proxmox Estate

Deploying and operating a service — a platform, an app stack, an orchestrator, a business control
plane — onto the Proxmox estate, as an LXC container or a QEMU/KVM VM: reconning the artifact,
choosing and sizing the guest, hardening the placement, building and exposing it over the tailnet
with real TLS, proving it works, and folding it into the existing backup and documentation rules.

Class of task: stand up (or rehome) a self-hosted web app or control plane on a Proxmox host,
reachable over the tailnet with real TLS, contained so it cannot reach anything it was not given.
Applies to any product — the examples below are commands, not a specific app. It covers placement,
isolation, exposure and verification *around* a service, not the internals of the application itself.

Platform-specific deployment notes for Paperclip live in the `paperclip-creator` skill; the estate
layout, mechanics and placement rule are in `references/pve-estate.md`.

## When to Use

- The Captain asks to install, host, deploy, self-host or "run this on one of my PVE machines" — a
  third-party repo, platform, appliance or control plane — or to "pick a container for" a new service.
- Choosing which guest or which storage a new workload should live in, or deciding whether an
  existing guest may be reused. Load this **before** answering "which container should this go in?",
  because the credential-surface rule in step 3 is what decides that, not available RAM.
- Standing up a new self-hosted web app or control plane, or rehoming a service onto a different
  guest or host.
- Making an existing service reachable over the tailnet with real TLS.
- Renaming, resizing, hardening, backing up, restoring, or rolling back a Proxmox guest (LXC or VM).
- Listing, inspecting or creating VMs as well as LXCs.
- Deciding whether a new reachable service may share a container with an existing workload.
- Running a long remote build or install and needing it to survive the session.
- Diagnosing a service that works locally but misbehaves for remote clients or browsers — connection
  refused at the client's connection test, a login that appears to succeed then fails, a browser API
  that is suddenly `undefined`.

Not for: modifying an application's own source or configuration semantics (this covers placement,
isolation, exposure and verification *around* a service, not its internals); changing an existing
service's config in place with no new guest and no placement decision; plain Docker work on a host
Proxmox does not manage; Hermes profile/gateway/cron changes; application debugging with no
deployment step.

## Overview

For any task of the shape "install/run <platform> on my Proxmox host": recon the artifact, vet it,
choose and configure the guest, harden it, back it up, build and expose it, verify from the far side,
and roll it back if needed. The estate structure — node reality, guests, storage, backup jobs, and
how to reach LAN-only guests — is in `references/pve-estate.md`. Re-verify it with
`scripts/lxc-credential-audit.sh` rather than trusting the snapshot; the live commands are the
durable part, the recorded values are a snapshot that ages.

The blast radius is a home network and, increasingly, a business, not a lab. **Do not start with
`git clone`.** Vetting and placement come first.

## Procedure

### 1. Recon the artifact and reconcile the request against reality

**Never trust the brief.** The metadata attached to a URL (star counts, watchers, size) is
frequently stale or synthesised. Verify against the live API before reasoning about the project:

- `GET https://api.github.com/repos/<owner>/<repo>` — stars, forks, `subscribers_count`,
  `created_at`, `pushed_at`, license, open issues.
- **Tell for a fabricated or stale card: identical star and watcher counts.** Real repos have
  orders of magnitude fewer watchers than stars. Compare before believing.
- `GET /repos/<owner>/<repo>/commits?per_page=10` for velocity; `/releases` for a tag to pin.
- Read the tree (`/contents/`), `Dockerfile`, compose files and `.env.example`. The deployment shape
  is in those, not in the README prose.

Then reconcile the request against the estate. Requests routinely assume more infrastructure than
exists, or assume software that was never installed.

```bash
pvecm status                      # clustered? nodes?  (missing corosync.conf = standalone)
ls -1 /etc/pve/nodes/             # the real node list
pct list ; qm list                # guests on THIS node
pvesm status                      # storage + free space per store
```

Sweep for additional PVE nodes rather than believing the count in the request — probe tcp/8006
across the LAN from an existing node. Verify whether the software you were told to remove is
actually installed (`dpkg -l | grep <pkg>`) instead of removing nothing and reporting success.
**Report a correction to the Captain's premise rather than quietly working around it.** "You have
one PVE machine, not several" is a finding he needs, not an inconvenience.

### 2. Security gate — vet before any placement decision

Run the advisory sweep and read the deployment-mode documentation. Full checklist:
`references/third-party-security-vetting.md`. The three questions that decide placement:

1. **Default auth posture?** A project whose default mode is no-auth is reachable by anything that
   can route to it until you change it.
2. **Does it execute code?** A platform that spawns CLIs, shells or build steps as child processes
   is an execution surface, not a web app.
3. **What credentials does it inherit?** Local-CLI/process adapters read the ambient environment and
   filesystem. See the credential-surface rule in step 3 — this is the deciding one.

"Popular and MIT-licensed" is not a substitute for the review. Present findings as a severity table.

Recon the estate for the placement call (`references/pve-estate.md` has the full command set):

```bash
pvecm status; ls -1 /etc/pve/nodes/     # clustered or standalone, and which nodes exist
pct list; qm list                        # guest inventory
pvesm status; free -m; df -h /           # capacity
pvesh get /cluster/backup --output-format json   # existing backup jobs
ip -br a | grep -E 'vmbr|eno|eth'        # is this host also the LAN gateway?
```

- **Pitfall — the PVE host is often also the LAN router and DNS.** If `vmbr0` holds the gateway
  address, the box routes the whole house and a compromise there extends to every device he owns.
  Containment becomes a hard requirement, not a preference. Say so explicitly.
- **Pitfall — Tailscale is not a complete inventory.** A PVE node or guest that is not on the
  tailnet is invisible to `tailscale status`. Sweep the LAN for the web UI port to be sure you have
  found every node before declaring "you only have one".

### 3. Placement — the ambient credential-surface rule

**Deploy into a container whose ambient credential surface is EMPTY.** A service that executes
code — an agent runtime, an orchestrator, a CI runner — inherits the container's entire environment
and filesystem. Its own sandboxing is irrelevant if the container it sits in is credential-dense:
anything it can read, a compromise of it can read. So the placement question is not "does this
container have free RAM", it is **"what does a process in here already have access to?"**

Run `scripts/lxc-credential-audit.sh` (read-only) and disqualify any candidate that presents:

| Signal | Why it disqualifies |
|---|---|
| `/var/run/docker.sock` | Root-equivalent by definition |
| Docker Engine API exposed (`dockerd` on :2375, a remote agent on :2376) | The same root, over the network |
| Portainer / portainer_agent | Container control UI |
| Browser terminal (termix and similar) | Interactive shell into the guest |
| Reverse-tunnel agent (rport, ngrok-likes) | A designed-in inbound path |
| Secret-bearing automation (n8n, Semaphore/Ansible, CI runners) | Holds third-party credentials in bulk |
| TLS ingress tunnel (cloudflared) | Public reachability |
| Network controller (UniFi, router/DNS duties) | Controls the network layer itself |

- **Never colocate with a live production guest.** Every running guest has a Docker socket and an
  ingress path *because that is what makes it useful*. That is a property, not bad luck. Steer the
  Captain off each nominally-attractive live guest with the specific evidence from that guest.
- **Correct the "a new guest costs too much RAM" objection with the mechanism.** LXC `memory=` is a
  cgroup **ceiling, not a reservation**. Over-committing is how these hosts already run (the
  configured totals across `/etc/pve/lxc/*.conf` commonly exceed physical RAM). A new guest at
  `memory=3072` costs approximately nothing while idle — so reusing a live production guest buys no
  RAM, only shared failure. This objection is raised every time; answer it with the fact.
- **Safe reuse** is limited to a guest that is stopped and holds nothing live: verify with
  `pct status <id>`, and check the raw disk is sparse before assuming it has contents
  (`ls -la <images-dir>/<id>/`). A guest's *name* is not evidence of its contents — verify what is
  actually installed before removing anything or claiming you removed it. Candidates that look like
  spares usually are not: a guest named for a decommissioned role may still hold a service, and
  "stopped" does not mean "empty". An empty, long-stopped guest is a legitimate reuse when he wants
  to avoid adding a guest — already sized, already on disk, holding nothing live. Wipe it and take
  it; take a `vzdump` first even if it looks pristine.
- Prefer, in order: a stopped guest you can wipe (cheapest, already sized), then a new guest.
- Prefer the thin/empty pool with genuine free space over the directory storage holding production.

### 4. Size and configure the container

```bash
pct start <ctid>
pct set <ctid> --hostname <name> --cores <n> --memory <mb> --swap <mb> \
             --features "nesting=1,keyctl=1"          # both required for Docker-in-LXC
# /dev/net/tun plumbing, so a tailnet identity can be added later without a second edit
cat >> /etc/pve/lxc/<ctid>.conf <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
```

- House pattern: `unprivileged: 1`; DHCP on `vmbr0` with `firewall=1`; `onboot: 1`; rootfs on the
  storage with real free space.
- `nesting=1,keyctl=1` is required for Docker inside the LXC.
- `lxc.cgroup2.*` is the cgroup-v2 form. The older `lxc.cgroup.devices.allow` still works but emits
  a deprecation warning under PVE 9 on every `pct` invocation, which pollutes every command's
  output — do not copy it forward from legacy guests.
- Tailscale/WireGuard inside the LXC needs the tun plumbing above.
- `memory`/`cores`/`features`/`hostname` changes need a restart: `pct set <id> --memory N --cores N
  --hostname X` then `pct reboot <id>`. Raise cores/memory **only for a heavy first build**, then
  return to steady-state sizing with a restart — and note that you owe a revert.
- Renaming a guest for Proxmox purposes is `pct set <id> --hostname <name>`; that is also the name
  column in `pct list`. Write `/etc/hostname` and a `127.0.1.1` line in `/etc/hosts` inside the
  guest too, or the guest disagrees with the panel:
  ```bash
  pct exec <id> -- bash -lc 'echo <name> > /etc/hostname; grep -q <name> /etc/hosts || echo "127.0.1.1 <name>" >> /etc/hosts'
  ```
- Confirm boot by polling rather than sleeping:
  `for i in $(seq 1 30); do pct exec <id> -- true 2>/dev/null && break; sleep 3; done`
- On a long-stopped guest, run a full `apt-get full-upgrade`, check `/var/run/reboot-required`, and
  reboot **before** installing anything. A large upgrade on an aged guest sets `reboot-required`,
  and building or installing on top of a pending libc/systemd update invites a confusing failure.
- Install Docker from Docker's own repository, not the distro package.

### 5. VM operations — list, inspect and create (`qm`)

The estate carries both LXC containers and QEMU/KVM VMs. Treat them as two different tools, not as
interchangeable guest slots.

**Listing and inspecting both guest types:**

```bash
pct list                      # LXC containers on this node (Name column = config hostname)
qm list                       # QEMU VMs on this node
pct status <ctid>             # running / stopped
qm status <vmid>              # running / stopped
pct config <ctid>             # full LXC config
qm config <vmid>              # full VM config
```

- **Current status** is `pct status` / `qm status`. For live per-guest resource counters, use the
  PVE web UI or its API form, e.g. `pvesh get /nodes/<node>/qemu/<vmid>/status/current` (and the
  `.../lxc/<ctid>/...` equivalent) — `pct`/`qm` alone report state, not usage.
- **Which storage a guest uses** is on the disk line of its own config: an LXC shows
  `rootfs: <storage>:...`; a VM shows it on its disk controller line (e.g. `scsi0: <storage>:...`,
  `virtio0:`, `sata0:`). Read the config — do not infer the backing store from inside the guest.
- **Which backup jobs a guest belongs to:** `pvesh get /cluster/backup --output-format json` and
  match the vmid against each job's `vmid` list. Remember to check each job's `enabled` flag.

**Creating a VM — `qm create` essentials:**

```bash
qm create <vmid> --name <name> --cores <n> --memory <mb> \
  --net0 virtio,bridge=<bridge> \
  --scsi0 <storage>:<size-gb> \
  --ide2 <iso-store>:iso/<image>.iso \
  --ostype l26
qm start <vmid>
```

- The essentials are `--cores`, `--memory`, a disk on a **named storage** (`--scsi0 <storage>:<size>`
  or the equivalent controller flag), and a NIC on the bridge the other guests use (`--net0
  virtio,bridge=<bridge>`, e.g. `vmbr0`).
- **A VM is useless until it has bootable content.** Unlike an LXC, which starts from a downloaded
  template, a QEMU VM needs an operating system: either attach an installer ISO (`--ide2
  <iso-store>:iso/<file>.iso`, or the `--cdrom` shorthand) and install, or import an existing disk
  image with `qm importdisk`. A VM with a disk but no OS simply will not boot.
- **A VM is not interchangeable with an LXC for Docker-inside purposes.** An LXC (with
  `features: nesting=1,keyctl=1`) runs Docker directly on the host kernel and shares it; a VM runs
  its own kernel and gives complete isolation, and Docker inside it needs no nesting/keyctl — it is
  just a machine. For a Docker workload an LXC is usually the lighter choice; for kernel isolation
  or a non-Linux guest a VM is the right tool. Do not propose one as a drop-in for the other.
- **What must be checked per host before creating a VM** — say plainly what you verified rather than
  assuming:
  - a storage whose `content` list includes `images` (and `iso` for the installer) — check
    `/etc/pve/storage.cfg` or `pvesm status`;
  - the target bridge exists on the node (`ip -br a | grep <bridge>`);
  - the node has enough real free disk on that storage for the disk size — a VM disk is typically
    allocated up front, unlike a sparse LXC rootfs;
  - whether the guest needs the QEMU agent for graceful shutdown and inventory.
- VM `cores`/`memory` changes need a stop/start (or `qm set` plus a reboot); the same "temporary
  bump for a build, then revert" rule as LXC applies.

### 6. Rollback point and backups

**Take a restore point before anything destructive:**

```bash
vzdump <id> --storage <backup-store> --mode snapshot --compress zstd --notes-template '<what state this captures>'
```

Then **verify the artefact exists** (`ls <store-path>/dump/ | grep <id>` plus `pvesh get
/nodes/<node>/tasks --typefilter vzdump`) — do not infer success from an exit code. An invoked
vzdump is not a completed backup: partial archives still emit progress lines that read like success,
and a truncated console view can hide the failure entirely. If the guest is stopped and pristine, the
dump is cheap insurance; if you have already modified it, the useful dump is the *current*
pre-install state, not a notional "before".

A storage only accepts dumps if its `content` list includes `backup` — check `/etc/pve/storage.cfg`
for the path behind each store name before assuming where dumps go. Several stores can point at the
same underlying filesystem; look at the `path`, not the label.

**Wire into the existing backup jobs — read, then extend; never hand-edit `/etc/pve/jobs.cfg` (it is
pmxcfs-backed):**

```bash
pvesh get /cluster/backup --output-format json        # id, storage, enabled, vmid, schedule
pvesh set /cluster/backup/<job-id> --vmid a,b,c,<new-id>
```

`pvesh set ... --vmid <list>` **replaces the whole vmid list**, so pass the complete set,
comma-separated. Inspect `enabled` before telling the Captain it is "in the backups" — a host may
carry three jobs where one is disabled, and job ids are opaque (`backup-<uuid>`). Register the guest
in **every** enabled job; query the jobs, do not assume there is one. Report which jobs received the
guest and which were deliberately left alone.

### 7. Install the service and harden its surface

1. `apt-get update && apt-get -y full-upgrade` on a dormant container first; it will leave
   `/var/run/reboot-required`, so reboot before installing the runtime.
2. Install the runtime from the vendor's apt repo rather than a convenience `curl | sh` script.
3. **Keep deployment config outside the git checkout**, in three separate directories, so a
   `git pull` never collides with the compose file:
   ```
   /opt/<app>/            git checkout, pinned to a release tag
   /opt/<app>-deploy/     compose file + .env (mode 0600) — survives `git pull`
   /opt/<app>-data/       persistent volume: database, workspaces, generated secrets
   ```
4. **Pin a release tag, never the default branch, and prove the pin:**
   ```bash
   git clone --depth 1 --branch <tag> <url> /opt/<app>
   cd /opt/<app> && git rev-parse HEAD && git rev-parse <tag>^{commit}   # must match
   ```
   Record the resolved commit hash — a tag alone is not an identity if it can be moved. Note that
   `git describe` on a shallow clone can report a *different* tag name for the same commit — compare
   commit SHAs, not tag strings.
5. **Read the Dockerfile before building to find the intended target.** The default build target is
   the *last* stage in the file, which is frequently a heavier variant (bundled plugins, cloud
   features) than a self-hoster should run. Comments in the Dockerfile usually name the target CI
   uses for self-hosted builds — use that, and pin `build.target`. Getting this wrong is what makes
   a build take an hour on consumer hardware.
6. **Environment changes require recreate, not restart:** `docker compose up -d --no-build`.
7. Publish ports to **specific addresses** (LAN IP + tailnet IP), never `0.0.0.0`, on any host with
   a public interface, and set the app's allowed-hostnames/trusted-origin allowlist to match every
   alias you will browse to, or logins fail on the private hostname. Validate the compose file with
   `docker compose config --quiet`.
8. Note any port deliberately *not* published (e.g. loopback). Write it down, or you will waste time
   health-checking the one address that cannot work.
9. **Recover the consumer's adapter contract from the artefact, not from prose.** When another system
   will drive this service (an agent platform calling an orchestrator, say), the authoritative field
   names and probe paths are usually compiled into the image: grep it for a `*-doc.js` / `*-doc.ts`
   under its adapters directory and read that. Then curl the **exact paths that consumer probes**
   and confirm each behaves as a live route rather than a 404 — a 200 on the health path and a 400 on
   the run path (not 404) means the route exists and is waiting for a body.
10. **Read the adapter roster to choose between sibling adapters.** Prefer the variant that reaches
    the already-running remote service over the one that spawns a local CLI inside the container: the
    local variant needs the dependency installed in this guest and yields a contextless instance with
    no persona, skills or memory, which is almost never what the Captain means.

**Hardening defaults for anything with an API or agent surface:**

- Deployment mode: **`authenticated` + `private`**. Never a no-auth "local trusted"/"development"
  mode and never public exposure for a business service. No-auth local modes have shipped with
  drive-by RCE via DNS rebinding in real platforms — the browser is the attack vector, so "it's only
  localhost" is not a mitigation.
- **Check whether the platform's own registration is open, and close it.** Self-hosted multi-user
  platforms routinely ship with self-service sign-up enabled by default, and `authenticated` mode
  alone does *not* stop a stranger creating an account. Locate the switch (usually an env var or a
  file setting, e.g. `*_DISABLE_SIGN_UP` / `auth.disableSignUp`) and sequence it correctly: **let
  the Captain bootstrap the owner account first, then disable sign-up and restart.** Disabling it
  before he signs up locks him out of his own instance. State the width of the window in plain terms
  — on a LAN+tailnet bind, "reachable" means every device on the home network plus every tailnet
  device.
- Publish ports on **specific addresses** (LAN IP + tailnet IP), never `0.0.0.0`.
- Set the platform's allowed-hostname / trusted-origin allowlist for every alias you will browse to.
- Give the service its **own** provider/API credentials with per-agent budget caps — never the
  fleet's keys. This is the Captain's standing separation rule.
- Leave a documented revert for any temporary sizing change made for a build.

### 8. Expose over HTTPS on the tailnet only

Use `tailscale serve` for TLS: it issues a genuinely trusted certificate, so clients need no TLS
bypass. Mechanics, port selection and verification: `references/tailnet-https-exposure.md`.

- Never bind a management or agent API to `0.0.0.0` on a host with a public IP. Bind the tailnet
  address, or loopback plus a proxy.
- Check `tailscale serve status` **before** adding a mapping — HTTPS ports are commonly already
  taken by unrelated services — and re-verify every pre-existing mapping afterwards.
- The serve target must be an address the service actually binds. If it binds a specific overlay IP,
  `http://127.0.0.1:<port>` is refused.
- Verify from the **far side** (another machine, or inside the client's own container), because DNS
  resolution and certificate trust are what break there.

**HTTPS is not cosmetic.** Serving an app over plain HTTP to a non-loopback host breaks browsers in
ways that present as application bugs, not as "the origin is insecure":

- **Secure-context-only browser APIs are `undefined`.** `crypto.randomUUID` (and most of
  `window.crypto`) exists only in a secure context, so an unguarded call throws on a plain-HTTP
  origin — often in exactly the credential-save step the user is trying to complete.
- **`Secure` cookies are silently discarded.** A login can return `200` with a `Set-Cookie` and the
  very next request comes back `401`, because the browser never stored it.

Symptom → mechanism → fix, plus the log-reading trick that identifies which origin a user is
actually on: `references/browser-secure-context-failures.md`.

**Design consequence worth stating up front:** once an app's canonical URL is HTTPS, its cookie
policy usually becomes instance-wide, so direct-IP HTTP ports stop being able to authenticate even
though they still serve the page. That is confusing and expected — tell the user the HTTPS URL is
the only entry point.

### 9. Secrets

- The secret scanner corrupts secret literals in file writes, heredocs and Docker builds.
  **Split-assemble** the value: `K1="prefix-"; K2="rest"; printf '%s%s\n' "$K1" "$K2" > file`.
- Never put a key on a command line. Stage it into the guest with `pct push ... --perms 600`, hand
  it to the tool as a **file** (e.g. `--auth-key=file:/path`), then `shred -u` it and verify removal.
- When displaying an `.env` for the record, mask it: `sed -E 's/(KEY|SECRET)=.*/\1=<redacted>/'`.
- Generate secrets on the target (`openssl rand -hex 32`) and never echo them; `.env` mode 600.
- One-time credentials (tailnet auth keys, enrolment tokens) are consumed on use. Tell the Captain
  to revoke them when the job is done.

**One-time provider auth keys (Tailscale pattern)** — a token passed as a command argument lands in
argv and shell history. Instead:

1. Assemble the value from split string parts inside the script so simple pattern-matching redaction
   cannot mangle it (`K1="prefix-"; K2="rest"; KEY="$K1$K2"`).
2. `umask 077`, write to a temp file, then `pct push <id> <src> <dst> --perms 600` and delete the
   host copy.
3. Consume it via the tool's file form — e.g. `tailscale up --auth-key=file:/root/.tskey`.
4. `shred -u` the file and verify it is gone.
5. Tell the Captain to revoke the key in the provider console.

To join a guest to the tailnet with Tailscale: add the tun plumbing (step 4), install from the
vendor apt repo, `tailscale up --auth-key=file:… --hostname=<guest-name>`, then confirm
`tailscale ip -4` and the MagicDNS name — that name has to be added to the platform's
allowed-hostname list and to the published port bindings.

### 10. Access and SSH

- "Keep the credentials I'm used to" means copying the existing public `authorized_keys` from a host
  that already works: `pct exec <id> -- bash -lc 'cat > /home/<user>/.ssh/authorized_keys' < source`.
  Never invent keys, and never print key material — report counts only.
- **A guest's own admin access keys are not "ambient credentials"; production service credentials
  are.** Reusing a container while preserving the Captain's SSH/sudo access is fine and expected.
  Copying `authorized_keys` from a working host is the right way to restore his access — and widen
  `from=` to include the LAN range when the new guest has no tailnet address yet, or you lock him
  out of a box he can only reach over the LAN.
- **A `from="<tailnet-cidr>"` tailnet-only restriction locks you out of a guest that has no
  Tailscale.** Widen it to include the LAN range (`from="<tailnet-cidr>,<lan-cidr>"`) while the
  guest is LAN-only, then narrow it back once the guest is on the tailnet — and say so, because it
  deviates from the house convention. The matching private keys live on the operator's devices, not
  on the host you copied from.
- Test SSH **from a host that actually holds the private key**. Testing from the PVE node itself
  proves nothing (no matching private key), and `ssh -J <pve-host> ...` executed *on* `<pve-host>`
  is a self-SSH that always fails with `Permission denied`, which looks like a key problem and is
  not. Reach a LAN-only guest with `ssh -J <pve-host> <user>@<guest-ip>` from a machine that has the
  key.

### 11. Long builds and long remote work

A first build that compiles a native toolchain can run for the better part of an hour on weak
hardware.

**Never hold the chat turn open across a multi-minute foreground wait.** The desktop UI cuts off a
turn that runs too long and the Captain sees "The connection dropped before the reply finished".
Nothing is lost — the work runs on the remote host, not in the session — but the reply is lost, and
it will look like a crash. Follow this pattern instead:

1. **Launch detached on the target host with a log file**, so a dropped session cannot kill the job:
   `setsid nohup env DOCKER_BUILDKIT=1 docker compose build > /var/log/<app>-build.log 2>&1 < /dev/null &`
2. Have a watcher write a **status line** (progress marker, artifact presence, free disk) to a file
   every ~30 s, and write a terminal `RESULT: ...` line when the image appears, the process dies, or
   an error matches. Poll that file rather than the build log.
3. Poll with **short** calls (seconds each) reading the status file.
4. End the turn with a status; let a tracked background job with `notify=true` bring you back.

**Detect completion by the artifact, not the log text:** `docker images -q <img> | wc -l`. "I saw no
error" is not a build result.

**Never grep a build log for a bare `ERROR`.** BuildKit echoes raw `RUN` command lines, so a
Dockerfile that legitimately contains `echo "ERROR: ..."` fires immediately. A watcher filtering on
`ERROR|error:|failed to solve` reports a false failure for a build that is progressing normally,
then *stops writing status* — so the false failure also blinds you, and the next poll reads a frozen
log as a stall. Match real failure markers instead: `^#[0-9]+ ERROR:`, `failed to solve:`,
`process "/bin/sh -c" did not complete successfully`. Sanity-check any reported failure against the
last few `DONE` lines before believing it.

**Watch free disk during the build** — build cache, node/pnpm layers and intermediate layers are
large (10 GB+ is common) and pruneable; a 30 GB guest is comfortable but not generous.

Full detached-watcher recipe, honest error detection, and multi-hop quoting through
ssh → pct → docker: `references/remote-build-and-long-job-execution.md`.

### 12. Verify, then close out

- **Health-check a published address, never `127.0.0.1`**, when ports are published per-address.
  Hit the health endpoint, then re-test it **over the access path you configured** (e.g. from a
  different machine across Tailscale), not just on localhost. Re-check any pre-existing inbound path
  on that host — a new listener can displace it.
- **Prove a route exists by its shape, not just its presence.** A `400` on an empty body means the
  route exists and validates; a `404` means the path is wrong. An unauthenticated `401` proves auth
  is enforced. Assert the specific code you expect; never conclude a route works from a `200` on a
  different path.
- **After any external write, read it back from the far side.** Fetch the pushed artifact back out
  of the remote system and inspect it, and compare local and remote revision identifiers. A
  successful push command is not evidence that the intended content landed.
- Test the negative case deliberately: a wrong key must be rejected, a disabled feature must
  actually refuse. A guard you have not seen fire is not a guard.
- **Define what "working" looks like and assert that specific thing** — an image present, a health
  endpoint returning its documented body, the service answering on **each** interface you bound.
  Success is an observable artifact, not the absence of errors.
- **Revert any build-time resource bump** and confirm the service returns after the restart. Size
  steady state against measured usage (`docker stats --no-stream`, `free -m`), not the peak.
- Hand the Captain any first-run **claim/enrolment URL** so he sets his own credentials. Never
  create credentials on his behalf.
- **When setup needs an authenticated session you do not have, stop and hand over exact values.**
  App-side setup APIs are owner/board-authenticated, and their CLI login flows are frequently
  interactive-only and refuse scripting. Never request the account password, and do not attempt to
  borrow his logged-in browser unless the configured browser backend can actually reach that
  profile. Give him the precise field-by-field values to paste, and offer to run the scripted
  remainder the moment he can approve a login. Say plainly that you are blocked and why — do not
  report a half-done setup as complete.
- Add the new platform to the security-advisory watch so its advisories surface.
- Report unrelated findings you tripped over (exposed Docker APIs, web terminals, credential-dense
  guests) as separate work items rather than folding them in silently.

### 13. Reporting and walkthroughs

How this work is communicated matters as much as the commands.

- **Be brief.** No preamble, no restating the question, no tour of what you are about to do.
- **When asked for a value, output only the value.** "What is the URL?" — or where a key lives, or a
  port — wants one line in a code block: no validation, no context, no rationale, no recap of how
  you found it, no alternatives. Unprompted explanation is exactly what makes a reply read as long;
  he asks for context when he wants it.
- **For UI walkthroughs, give numbered literal steps** with the exact strings to paste and the name
  of the field to paste them into. A request for step-by-step help is a request for *foolproof*
  instructions: one action per numbered step, the literal value, and what he should see afterwards.
  Pre-empt the likely mistake: say *which* hostname, *which* port, *which* line of the file. Assume
  the user is tired and mid-task, not that they lack capability; prose interleaved between steps is
  what makes those instructions fail, and a wrong-value paste is the predictable result of an
  instruction that made him hunt for which line to copy.
- **Give the distinguishing marks when pointing at a line in a long file.** A file position ("line
  488") plus a prefix/suffix and a length lets him confirm he has the right value without exposing
  the secret. "It's in the .env" is not an instruction.
- **Lead status with verified facts, not narrative.** A compact table of what is now true — values,
  paths, states — beats a story of what you did, because he tracks state by artifact. Say which
  claims a live command confirmed and which are inferred.
- **Distinguish the two hosts by role in every instruction.** When the setup spans more than one
  machine, name which one each step happens on, every time. Similarly-named hosts are the single
  most reliable source of wasted round-trips.
- **Do not narrate intent.** Do the work, then report what changed; "I will now…" is not a
  deliverable.
- **Never hold a chat turn open across a multi-minute wait** — it gets cut off mid-reply and the
  user sees a connection error. Detach the work, report state, end the turn.
- Own your own mistakes explicitly and separately from the user's. If a change you made caused their
  symptom, say so in the first sentence.

## Pitfalls

- **Nested quoting through `pct exec` will break.** `ssh <pve-host> "bash -lc '...docker --format
  {{.Image}}...'"` fails with `command not found` or `unexpected EOF while looking for matching
  quote`. Write the probe as a local file and pipe it: `ssh <user>@<pve-host> 'sudo -n bash -s' <
  probe.sh`. Use this for anything containing nested quotes, `{{ }}` templates, awk, or `$` — and
  inside such scripts prefer `ss -tlnH` (no header) over `awk 'NR>1'` header-skipping, which is
  where the escaping dies.
- **`grep -c` prints `0` AND exits non-zero**, so `n=$(grep -c pat f || echo 0)` yields `"0\n0"` →
  `"00"`, which is `!= "0"` and silently inverts a completion check. Use `grep -c pat f; true` or
  `cmd | wc -l | tr -d ' '`. Never build a done/not-done test on the `|| echo` idiom.
- **A `-J`/jump-host test executed from inside the script's own host self-SSHes** and reports
  `Permission denied`. When verifying reachability, run the jump from the machine that actually
  holds the private key.
- **The `terminal` tool's wait parameter is `timeout` (seconds), not `timeout_s`.** `timeout_s` is
  the *browser* tool's parameter name. Passed to `terminal` it is silently ignored — an unrecognised
  parameter is silently ignored rather than raising — so the 180 s default cap applies and a longer
  command is killed with `Command timed out after 180s`, with no hint that the parameter you set was
  never read. This looks exactly like the remote host being slow, which is how it burns an hour. A
  `terminal` foreground timeout above 600 s is converted to a tracked background job with notify.
  Set `timeout=` for anything that might exceed two minutes, and prefer the detached pattern
  (step 11) so the cap never becomes the deciding factor.
- **Never bind a long remote build to the agent's session or to a long poll.** Launch a detached
  watcher *inside the guest* that appends progress plus a terminal sentinel to a status file
  (`setsid nohup … &`), then poll that file with cheap calls — or run the wait itself as
  `background=true, notify=true`.
- **A stopped container's name is not its contents.** Verify the footprint (`dpkg -l | grep <pkg>`,
  service list, `du -sh` the expected paths) before removing or claiming you removed software.
  Candidates that look like spares usually are not.
- **Verify a mirror/route with a deliberate empty body.** `400` proves the route exists and
  validates; `404` means the path is wrong. Never conclude a route works from a `200` on a
  different path.
- **Judging tenancy by the feature list:** a platform advertising "multi-company with complete data
  isolation" tells you nothing. Judge it by its advisory history — repeated cross-tenant
  token/id/key IDOR findings mean multi-tenancy is unproven, and client data must not share an
  instance until it is independently proven.

## Choosing the model for a deployed agent platform

When the platform's agents need their own provider/model, never pick from the README:

1. `GET https://<provider>/api/v1/models`; filter to models advertising tool calling and meeting
   the context floor for the workload.
2. **Probe with a real tool-calling request.** Catalogue metadata lies: in practice several
   plausible cheap models emitted no tool call at all. Measure whether a call is emitted, the
   latency, and the actual `usage.cost`.
3. **Raise `max_tokens` before rejecting a model.** A tight cap starves reasoning models, which then
   produce zero tool calls as a token-budget artifact rather than a capability gap — a false
   negative that will mislead you. Retest generously before discarding.
4. Prefer a non-China jurisdiction when the work will touch client data. State it once, then respect
   the Captain's decision and stop re-litigating it.
5. Use the platform's **own** key, separate from the fleet's — standing separation rule.

## Documentation (standing rule)

After any change of this kind, update the local docs **and** push to the GitHub config repos in the
same session. Record: guest id/name, purpose, resources, storage, port bindings, backup job
membership, and any deliberate deviation from house convention. Do not report the task complete
before docs are synced.

## References

- `references/pve-estate.md` — the live estate: node reality and gateway role, guest inventory with
  each one's credential profile, storage pool layout, backup jobs, LAN-only access via jump host,
  the LXC flag reference, discovery/backup/file-transfer mechanics, Tailscale-in-LXC, and the
  ambient-credential-surface placement rule.
- `references/third-party-security-vetting.md` — the pre-deployment security checklist: advisory
  sweep, deployment-mode reading, execution-surface questions, credential-inheritance rule,
  reporting shape.
- `references/remote-build-and-long-job-execution.md` — detached remote jobs with a status file and
  a notify waiter; honest error detection in build logs; multi-hop quoting through ssh → pct →
  docker; secret staging.
- `references/tailnet-https-exposure.md` — `tailscale serve` mechanics: port selection, target
  selection, verification, coexistence with existing mappings.
- `references/browser-secure-context-failures.md` — secure-context symptoms, causes, fixes, and how
  to tell which origin a user is on from the server log.
- `scripts/lxc-credential-audit.sh` — read-only audit of every guest's ambient-credential surface,
  plus backup-job listing. Run before choosing a colocation target.

Platform-specific deployment notes for Paperclip live in the `paperclip-creator` skill.
