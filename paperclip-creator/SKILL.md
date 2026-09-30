---
name: paperclip-creator
description: "Use when deploying Paperclip (agent-company platform). Stand up the instance in a container, wire a Hermes gateway agent as a worker, and avoid the traps that break self-hosting."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [self-hosting, agents, orchestration, docker, proxmox, security]
    related_skills: [hermes-agent, proxmox-lxc-deployment, native-mcp]
---

# Paperclip Creator

Paperclip is an open-source (MIT) agent-orchestration platform: a Node server plus React UI that
runs an organisation of AI agents against business goals, with org charts, budgets, heartbeats,
and a task board. This skill covers standing it up, connecting a **Hermes Agent** as a worker, and
the specific traps that make a self-hosted Paperclip look broken when it is not.

Everything here was learned by deploying it for real and debugging each failure to its source line.
Placeholders (`<pve-host>`, `<ctid>`, `<tailnet-ip>`, `<profile>`) mean: substitute your own.

---

## 1. Decide before you build

| Decision | Choose | Why |
|---|---|---|
| Deployment mode | `authenticated` + `private` | **Never `local_trusted`.** That default shipped a drive-by RCE via DNS rebinding (GHSA-x8hx-rhr2-9rf7). |
| Build target | `--target production` | The default last stage is a heavier cloud variant. Paperclip's own Dockerfile notes CI pins `production` for self-hosted images. |
| Source version | a **release tag**, never the default branch | The project moves fast — roughly 150 commits in a day is normal. |
| Agent transport | `hermes_gateway` | `hermes_local` spawns the CLI *inside* the Paperclip container: a blank agent with no persona, skills, or memory. The gateway reaches your real, already-running profile. |
| Host | its **own** container, never shared | This is a control plane that spawns child processes inheriting the container's whole filesystem. Sharing it with another service means sharing that service's credentials. |
| Tenancy | one instance = one organisation | Multiple critical cross-tenant isolation advisories in the first year. Treat multi-tenant isolation as unproven. |

## 2. Deploy the instance

```bash
# on the container host — <ctid> is the guest id
pct set <ctid> --hostname paperclip --cores 4 --memory 6144 \
               --features "nesting=1,keyctl=1"
pct reboot <ctid>
```

`nesting=1` and `keyctl=1` are both required for Docker inside an unprivileged LXC.

```bash
# inside the guest
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get -y -qq full-upgrade      # then reboot if asked
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get -y -qq install docker-ce docker-ce-cli \
    containerd.io docker-buildx-plugin docker-compose-plugin

# pin the source
git clone --depth 1 --branch <release-tag> https://github.com/paperclipai/paperclip.git /opt/paperclip
git -C /opt/paperclip rev-parse HEAD      # record this
```

Keep deployment config **out of** the git checkout so updates stay clean:

```
/opt/paperclip/          git checkout, pinned tag
/opt/paperclip-deploy/   docker-compose.yml + .env (0600)
/opt/paperclip-data/     persistent volume: embedded Postgres, workspaces, secrets key
```

Compose essentials — the parts that matter:

```yaml
services:
  paperclip:
    build:
      context: /opt/paperclip
      dockerfile: Dockerfile
      target: production                 # do not omit
    pids_limit: 2048                     # backstop; the image makes tini PID 1 to reap orphans
    ports:
      - "<lan-ip>:3100:3100"             # explicit addresses only — never 0.0.0.0
    environment:
      PAPERCLIP_DEPLOYMENT_MODE: "authenticated"
      PAPERCLIP_DEPLOYMENT_EXPOSURE: "private"
      PAPERCLIP_PUBLIC_URL: "${PAPERCLIP_PUBLIC_URL}"
      PAPERCLIP_ALLOWED_HOSTNAMES: "${PAPERCLIP_ALLOWED_HOSTNAMES}"
      BETTER_AUTH_SECRET: "${BETTER_AUTH_SECRET:?...}"
      PAPERCLIP_AUTH_DISABLE_SIGN_UP: "${PAPERCLIP_AUTH_DISABLE_SIGN_UP:-false}"
    volumes:
      - /opt/paperclip-data:/paperclip
```

Then:

```bash
cd /opt/paperclip-deploy && docker compose up -d --no-build
curl -s http://<lan-ip>:3100/api/health
```

**The build is heavy.** The dependency graph includes a Rust toolchain plus several npm-installed
agent CLIs. On a low-power CPU expect ~45 minutes. Run it detached with a log file; do not hold an
interactive session open across it.

> **Do not grep the build log for `ERROR`.** BuildKit echoes raw Dockerfile command lines, and one
> of them literally contains `echo "ERROR: server build output missing"`. A naive grep reports a
> false failure on a healthy build. Match only real failure markers:
> `^#[0-9]+ ERROR:` or `failed to solve:`, and detect success by the artefact
> (`docker images -q <image> | wc -l`).

## 3. Bootstrap, then immediately lock registration

Bootstrap is a **web-UI step**, not a token: with `authenticated` mode from the start there is no
board-claim URL, and the first account becomes the admin.

1. Open the instance and create the first account.
2. Create the organisation. **Note its prefix** (see §5).
3. Then close sign-up, in the same session:

```bash
# in .env
PAPERCLIP_AUTH_DISABLE_SIGN_UP=true
docker compose up -d --no-build     # env change needs recreate, not restart
```

Verify it actually refuses:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"probe","email":"probe@example.invalid","password":"x"}' \
  https://<host>/api/auth/sign-up/email
# expect {"code":"EMAIL_PASSWORD_SIGN_UP_DISABLED"}
```

**Sign-up is open by default.** The window between "it is up" and "the owner has claimed it" is
exactly when anything that can route to the port can register — and an unauthenticated sign-up was
step one of a critical upstream RCE chain.

## 4. Put it behind HTTPS — this is not optional

Two independent failures come from serving the UI over plain HTTP on a non-loopback host. Both
disappear with TLS:

- **`crypto.randomUUID is not a function`.** `window.crypto.randomUUID` exists only in a **secure
  context**. Agent setup calls it unguarded at `ui/src/lib/provider-credential.ts`, unlike its
  sibling call sites which all guard it, so saving an agent's credentials throws.
- **Login appears to succeed, then bounces.** Paperclip decides cookie security from
  `PAPERCLIP_PUBLIC_URL` (`server/src/auth/better-auth.ts`): if it starts with `http://`, secure
  cookies are disabled; if it is `https://`, they are enabled. A `Secure` cookie is silently
  dropped by the browser on an `http://` origin — the sign-in returns **200** with a session
  cookie, and the very next request is **401/403**.

A tailnet/reverse proxy issues a real trusted certificate, so nothing is bypassed. Example with
Tailscale, on the node that hosts the service:

```bash
tailscale serve --bg --https=443 http://<guest-lan-ip>:3100
```

Two details: pick a port that is free (`tailscale serve status` before and after), and if the
target service binds **only** a specific address, the proxy target must be that address — loopback
will be refused.

Consequence worth knowing: with `PAPERCLIP_PUBLIC_URL` on `https://`, the direct-IP HTTP ports can
no longer authenticate even though they still serve the page. Treat HTTPS as the only entry point.

## 5. Routes are organisation-prefixed

Host pages live under `/:companyPrefix/...`. **The first path segment is the company's
`issuePrefix`**, so `/X/agents` where `X` matches no company renders *"No company matches prefix"*
or *"org non existent"* — not a 404.

The prefix is derived from the company **name**: uppercase, strip non-`[A-Z]`, take the first three
characters, appending `A`/`AA`… only on collision (`server/src/services/issue-prefix.ts`). So
`"Acme Widgets"` → `ACW`, and the same code appears in task identifiers (`ACW-1`). Read the
derivation from source rather than guessing; the no-company fallback is `PAP`.

Also: **health checks must target a published address, not `127.0.0.1`** — the compose file
publishes only the addresses you listed, so loopback is deliberately not listening.

## 6. Connect a Hermes Agent

On the Hermes host:

```bash
hermes config set platforms.api_server.enabled true
hermes config set platforms.api_server.host <tailnet-ip>   # tailnet only, NOT 0.0.0.0
hermes config set platforms.api_server.port 8642
# store the bearer token in the target profile's .env; non-default profiles enforce >= 16 chars
```

That `.env` value is read at **process start**, so a restart is required and it must be **one**
restart — under multiplexing a single service serves every profile.

Under a multiplexed gateway the default profile owns the single HTTP listener and other profiles
are served at `/p/<profile>/`. The bearer token checked for `/p/<profile>/…` is that **profile's**
`API_SERVER_KEY`, not the default's.

Wire the agent in the UI with:

| Field | Value |
|---|---|
| Adapter | **Hermes Gateway** |
| API base URL | `https://<hermes-host>:<port>/p/<profile>` — **no `/v1` suffix** |
| API key | that profile's `API_SERVER_KEY` |
| Paperclip API URL | the Paperclip URL as reachable **from Hermes** |

The adapter probes `<apiBaseUrl>/health` and starts runs at `<apiBaseUrl>/v1/runs`. Verify both
before wiring:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<hermes-host>:<port>/p/<profile>/health      # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<hermes-host>:<port>/p/<profile>/v1/runs  # 400, not 404
```

A **400 on an empty body means the route exists** — that is success, not failure. A 404 means you
have the wrong prefix or the wrong host.

The adapter refuses plain `http://` to any non-loopback host. Use HTTPS; do **not** reach for
`dangerouslyAllowInsecureRemoteHttp`, which its own message describes as unsafe local development
only. The authoritative field spec is compiled into the server image at
`/app/server/dist/adapters/hermes-gateway-doc.js` — read it rather than guessing field names.

## 7. Cost reality

An agent's waking cost is dominated by **its own system prompt and tooling**, not by your prompt. A
large persona measured **~20,000 input tokens for a trivial request**. Prefer assignment-driven
wake-ups and long intervals over pure timers, and set a monthly budget on every agent — that budget
is the only thing between an agent loop and a large bill.

## 8. Security must-dos

- Never `local_trusted`; never `0.0.0.0`; never public internet.
- Close sign-up immediately after bootstrap.
- One instance, one tenant — do not put client data in it.
- Give the instance its **own** provider keys, separate from any other system's.
- The Hermes API server is **unsandboxed by default**: its own startup warning says dispatched work
  "runs as the host user with full terminal/file access". Either set `terminal.backend: docker` for
  that profile or give the platform a dedicated, narrowly-scoped profile.
- Watch upstream advisories. This project publishes them; subscribe to
  `github.com/paperclipai/paperclip` security advisories and patch on anything critical.

## 9. Verification checklist

- [ ] Image built from a pinned tag; commit hash recorded
- [ ] `/api/health` returns `{"status":"ok"}` **over HTTPS**
- [ ] `bootstrapStatus` moved from `bootstrap_pending` to `ready`
- [ ] Sign-up probe returns `EMAIL_PASSWORD_SIGN_UP_DISABLED`
- [ ] Correct organisation prefix identified from the source derivation, not guessed
- [ ] `/p/<profile>/health` → 200 and `/p/<profile>/v1/runs` → 400 (not 404)
- [ ] Agent connection test reads *"Connection successful"*
- [ ] Backups: the guest is in at least one enabled backup job, and the in-app hourly dumps exist
- [ ] Per-agent budgets set before leaving it unattended

## References

- `references/configuration-traps.md` — every failure above as symptom → cause → fix, with the
  source location where one exists
- `references/hermes-gateway-adapter.md` — the adapter's contract in full: fields, probes, network
  topology examples
