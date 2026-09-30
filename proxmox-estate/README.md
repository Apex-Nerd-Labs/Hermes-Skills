# Proxmox Estate — deploy, operate and recover a self-hosted service

> **One operational playbook for a Proxmox host: inventory the guests, place a workload correctly,
> deploy it, harden it, back it up, and prove the backup restores.**

Self-hosting goes wrong in the same handful of places every time: a service lands in a guest that
already holds credentials it should never see, a container is sized from a ceiling rather than a
measurement, a "successful" build was never actually verified, a backup is trusted because it
decompresses rather than because it contains the data. This skill is the procedure that avoids those,
written from real deployments and traced to the line where something broke.

Placeholders (`<pve-host>`, `<ctid>`, `<lan-ip>`, `<node>`, `<storage>`, `<profile>`) mean:
substitute your own.

## What's Included

| File | Purpose |
|---|---|
| `SKILL.md` | The whole procedure: recon, security gate, placement, sizing, **VM operations**, rollback and backups, install and hardening, HTTPS exposure, secrets, SSH access, long remote work, verification, reporting |
| `references/pve-estate.md` | Estate mechanics in depth: discovering the estate, the credential-surface enumeration, LXC config flags that matter, Tailscale inside an unprivileged guest |
| `references/third-party-security-vetting.md` | The pre-placement security checklist for an unfamiliar repo or appliance |
| `references/remote-build-and-long-job-execution.md` | Detached long builds: surviving session loss, and detecting success by artifact |
| `references/tailnet-https-exposure.md` | Exposing a service over HTTPS on a private overlay, and the port/address traps |
| `references/browser-secure-context-failures.md` | Why a UI works locally but misbehaves for remote clients over plain HTTP |
| `scripts/lxc-credential-audit.sh` | Audits a guest for ambient credentials before you place a workload in it |
| `MANIFEST.sha256` | Integrity manifest — verify your copy with `sha256sum -c MANIFEST.sha256` |
| `README.md` | This file |

## Quick Install

Copy-paste this to your Hermes agent (any profile):

```text
I want to install the proxmox-estate skill from github.com/ciberjohn/Hermes-Skills.
Copy the whole proxmox-estate/ folder — SKILL.md, README.md, MANIFEST.sha256, every file in
references/ (pve-estate.md, third-party-security-vetting.md,
remote-build-and-long-job-execution.md, tailnet-https-exposure.md,
browser-secure-context-failures.md), and scripts/lxc-credential-audit.sh — into
~/.hermes/skills/devops/proxmox-estate/, keeping scripts/ executable (chmod +x).

Then confirm the copy is intact before anything else:
cd ~/.hermes/skills/devops/proxmox-estate && sha256sum -c MANIFEST.sha256
```

Or install manually:

```bash
git clone https://github.com/ciberjohn/Hermes-Skills.git ~/Hermes-Skills
mkdir -p ~/.hermes/skills/devops
cp -r ~/Hermes-Skills/proxmox-estate ~/.hermes/skills/devops/proxmox-estate
chmod +x ~/.hermes/skills/devops/proxmox-estate/scripts/lxc-credential-audit.sh
cd ~/.hermes/skills/devops/proxmox-estate && sha256sum -c MANIFEST.sha256
```

## Why This Skill Exists

The expensive failures are not the obvious ones:

- A service is placed in a **stopped production guest** that still holds its credentials and data,
  so the new workload inherits a surface it was never granted.
- A container is sized from what the old guest *was configured with*, not from what it *used* —
  `memory=` is a ceiling, not a reservation.
- A long build "fails" because a monitor greps the log for `ERROR`, and BuildKit echoes a Dockerfile
  line that literally contains the word.
- A service answers locally but not for remote clients, because a browser API only exists in a
  **secure context** and the deployment is on plain HTTP.
- A backup passes every integrity check, restores cleanly, boots to a healthy API — and contains
  **none of the data**, because the data was created after the backup ran.

Each of those has cost somebody an afternoon. This is the procedure that front-loads them.

## Prerequisites

- A Proxmox VE host with LXC and/or QEMU guest support
- SSH access to that host (the procedure assumes non-interactive `sudo`)
- For the exposure steps: a private overlay network or reverse proxy with a trusted certificate
  (Tailscale is used as the worked example; the reasoning is not Tailscale-specific)

## Scope and Safety

This skill provisions and operates workloads, so it is explicit about the guardrails:

- **Vet before you place.** An unfamiliar repo gets a security review before a container is chosen —
  placement depends on what the workload can reach, not on which guest has free RAM.
- **Never publish to `0.0.0.0`.** Bind explicit addresses; treat a private overlay as the only entry
  point.
- **One service, one guest** for anything with an API, a Docker socket, or an agent surface.
- **Prove, don't assume.** Every step ends in an observable artifact — a bound port, a health
  response, a verified restore — not in the absence of an error message.

Read `SKILL.md` §2 and §3 before placing anything you care about.

## Usage

Ask your agent, in plain language:

```text
What guests do I have on <pve-host>, and which backup jobs are they in?
```

```text
Deploy <project> onto my PVE estate. Vet it first, then choose where it goes.
```

```text
Create a new VM on <pve-host> with 2 cores and 32 GB of disk.
```

```text
Test that the backup of <guest> actually restores, and prove it contains my data.
```

## Maintenance Note

`MANIFEST.sha256` covers `SKILL.md`, every file in `references/`, and the script in `scripts/`.
**If you edit any of them, regenerate the manifest in the same commit** — a stale manifest makes a
correct copy fail its own integrity check, which is the worst possible failure because it casts doubt
on the file rather than on the checksum. Note that `sha256sum -c` resolves the listed paths relative
to your **current directory**, so run it from inside the skill folder:

```bash
cd proxmox-estate
sha256sum SKILL.md references/*.md scripts/* > MANIFEST.sha256
sha256sum -c MANIFEST.sha256
```

## License

MIT — use freely, adapt as needed. Attribution appreciated but not required.
