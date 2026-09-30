# Paperclip Creator — deploy the agent-company platform and wire a Hermes agent to it

> **An operations runbook for a self-hosted agent orchestration platform.** Covers standing it up
> in a container, connecting a Hermes Agent profile as a worker, and the configuration traps that
> make a healthy install look broken.

[Paperclip](https://github.com/paperclipai/paperclip) is an open-source (MIT) platform that runs an
organisation of AI agents against business goals — org charts, budgets, heartbeats, a task board,
cost tracking. This skill gets it running properly, and front-loads the mistakes.

Every trap here was hit in a real deployment and traced to the source line that causes it. No
guessing, no "try this and see".

## What's Included

| File | Purpose |
|---|---|
| `SKILL.md` | The skill: decisions, deployment steps, HTTPS requirement, route structure, agent wiring, cost reality, security must-dos, verification checklist |
| `references/configuration-traps.md` | Twelve failures as **symptom → cause → fix**, each with the source location where one exists |
| `references/hermes-gateway-adapter.md` | The `hermes_gateway` adapter contract: payload fields, the probes it makes, profile routing, network topologies |
| `references/backup-and-restore-drill.md` | What to back up, how to verify a backup **by content**, and how to run a restore drill without disturbing the live instance |
| `references/platform-notes.md` | Deployment-mode table, the correct ordering for closing sign-up, first-run behaviour, published security history, compose variants and secret generation, and operating the source-only CLI |
| `MANIFEST.sha256` | SHA-256 of `SKILL.md` and the four references — verify your copy with `sha256sum -c MANIFEST.sha256` |
| `README.md` | This file |

## Quick Install

Copy-paste this to your Hermes agent (any profile):

```text
I want to install the paperclip-creator skill from github.com/ciberjohn/Hermes-Skills.
Copy the whole paperclip-creator/ folder — SKILL.md, README.md, MANIFEST.sha256, and every file
in references/ (configuration-traps.md, hermes-gateway-adapter.md, backup-and-restore-drill.md, platform-notes.md) — into
~/.hermes/skills/devops/paperclip-creator/.

Then confirm the copy is intact before anything else:
cd ~/.hermes/skills/devops/paperclip-creator && sha256sum -c MANIFEST.sha256
```

Or install manually:

```bash
# Clone the skills repo
git clone https://github.com/ciberjohn/Hermes-Skills.git ~/Hermes-Skills

# Copy the whole skill folder
mkdir -p ~/.hermes/skills/devops
cp -r ~/Hermes-Skills/paperclip-creator ~/.hermes/skills/devops/paperclip-creator

# Verify integrity
cd ~/.hermes/skills/devops/paperclip-creator && sha256sum -c MANIFEST.sha256
```

## Why This Skill Exists

Self-hosting Paperclip is straightforward until it is not, and the failure modes are deceptive:

- The instance looks broken when it is only being served over **plain HTTP** — two separate faults
  come from that one cause, one of them a browser API that only exists in a secure context.
- The login "works" and then does not, because a **cookie policy** flips when you move the
  canonical URL to HTTPS.
- A page says **"org non existent"** when the real problem is that the first path segment is an
  organisation code you have not checked.
- The agent test says "Couldn't connect" because the adapter **refuses plain HTTP to a remote host**
  — a protection, not a defect.
- A build monitor reports failure because BuildKit **echoes Dockerfile commands**, and one of them
  contains the word `ERROR`.
- A backup that passes every integrity check, restores cleanly and boots to a **healthy API** can
  still contain none of your data, because the data was created *after* the backup ran. Archive
  integrity is not backup validity.

Each of those has cost somebody an afternoon. The reference files exist so it costs you five
minutes.

## Prerequisites

- A container host (the skill is written against Proxmox LXC; any Docker host works)
- Docker with Compose v2
- A pinned release tag from `github.com/paperclipai/paperclip`
- A private network with working TLS (the skill uses Tailscale as the example, but any private
  overlay or reverse proxy with a trusted certificate works)
- For the agent integration: Hermes Agent with at least one profile you want to expose

## Scope and Safety

This skill provisions an **agent control plane that executes code**. It is explicit about the
guardrails that keep that survivable:

- never `local_trusted`, never `0.0.0.0`, never the public internet
- close registration immediately after bootstrap — the default is **open sign-up**
- one instance, one tenant: multi-tenant isolation has a documented history of failure
- the Hermes API endpoint is **unsandboxed by default** and must be scoped or sandboxed
- set per-agent budgets before leaving anything unattended

Read `SKILL.md` §8 before exposing an instance to anything you care about.

## Usage

Ask your agent, in plain language:

```text
Deploy Paperclip into a new container and wire my Hermes profile as the first agent.
```

or, for troubleshooting:

```text
My Paperclip agent says "Couldn't connect". Use the paperclip-creator skill to diagnose it.
```

or, for the route problem specifically:

```text
I get "org non existent" in Paperclip. Work out the correct URL from the source derivation.
```

## Maintenance Note

`MANIFEST.sha256` covers `SKILL.md` and the four files in `references/`. **If you edit any of them,
regenerate the manifest in the same commit** — a stale manifest makes a correct copy fail its own
integrity check, which is the worst possible failure because it casts doubt on the file rather than
the checksum:

```bash
cd paperclip-creator
sha256sum SKILL.md references/*.md > MANIFEST.sha256
sha256sum -c MANIFEST.sha256
```

## License

MIT — use freely, adapt as needed. Attribution appreciated but not required.
