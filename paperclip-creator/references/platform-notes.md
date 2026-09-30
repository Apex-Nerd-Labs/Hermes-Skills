# Paperclip — Setup Modes, Security History, and CLI

Platform orientation that does not belong in the deployment steps. Start with `SKILL.md`; come here
when you need the mode decision, the ordering subtleties, or to operate the instance from a shell.

---

## 1. Deployment modes

| Mode | Auth | Use |
|---|---|---|
| `local_trusted` | **none**, loopback bind | local play only — never anything reachable |
| `authenticated` + `private` | login (Better Auth) | LAN / tailnet / VPN behind TLS; `PAPERCLIP_BIND=lan\|tailnet` |
| `authenticated` + `public` | login + public URL | internet-facing; needs TLS and stricter config |

**`local_trusted` is the default and it has no authentication at all.** "It is only bound to
loopback" is not a defence: the drive-by DNS-rebinding advisory below defeats exactly that
assumption. Choose `authenticated` + `private` before the first boot, not after.

Set `PAPERCLIP_PUBLIC_URL` and `PAPERCLIP_ALLOWED_HOSTNAMES` from the start. The hostname list is
comma-separated and should carry the app name, every bound address, and the MagicDNS name — omit one
and logins from that host redirect-fail rather than erroring clearly.

## 2. Registration: order the two steps correctly

Sign-up is **open by default** (`server/src/config.ts` reads `PAPERCLIP_AUTH_DISABLE_SIGN_UP`,
falling back to `auth.disableSignUp ?? false`). The sequence matters, and getting it backwards locks
everyone out:

1. Let the operator bootstrap **first** and claim the first account.
2. **Then** set `PAPERCLIP_AUTH_DISABLE_SIGN_UP=true` and restart.
3. Verify with a real probe, not by reading the config:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"probe","email":"probe@example.invalid","password":"x"}' \
  https://<host>/api/auth/sign-up/email
# expect {"code":"EMAIL_PASSWORD_SIGN_UP_DISABLED"}
```

Disable it *before* the operator has an account and nobody can get in. Leave it open and anything
that can route to the port can register — which is itself step one of a documented RCE chain.

## 3. First-run behaviour worth expecting

- **Bootstrap is a web-UI step, not a token.** The first registered account becomes instance admin.
  There is no claim token when the instance starts directly in `authenticated` mode. (Some versions
  emit a one-time board-claim URL on first boot when starting in another mode — watch the logs.)
- **The first screen pushes provider onboarding (OpenAI/Claude). It is skippable.** That path is for
the *local-CLI adapters* and is irrelevant if you intend to use `hermes_gateway`.
- **The instance boots with no LLM key.** Adapters fail their prerequisite checks; the server does not
  fail to start. So a missing key is never a reason a deployment is "broken".
- **A first-run `database_backup_missing` warning is benign.** It clears once the first hourly backup
  runs.
- `GET /api/health` also reports `bootstrapInviteActive` alongside `bootstrapStatus`.

## 4. Published security history

Pinning is not set-and-forget — the release cadence is very high. The recurring classes:

| Class | Lesson |
|---|---|
| Drive-by RCE via DNS rebinding against the no-auth local mode | the victim only opens a page; commands run as the app's OS user |
| Unauthenticated RCE via an import authorisation bypass | open sign-up with no email verification was part of the chain |
| OS command injection through workspace lifecycle hooks | fields reaching `child_process.spawn` are the RCE surface |
| Repeated cross-tenant authorisation failures on agent-key routes | another company's agent token could be minted |
| Local-CLI adapters inheriting host credentials | a local agent run reached a connected account and sent real mail |
| Skills able to exfiltrate or destroy data | skill installation is a privileged operation |

The multi-company "data isolation" feature **is the surface that has broken repeatedly**. One
instance = one tenant. Do not put separate client organisations in a single instance.

Consequences for placement: give it a **credential-sterile container** — no Docker socket, no host
SSH keys, no personal provider tokens — with locked-down egress, on a host whose compromise you can
survive. That placement reasoning is the `pve-estate` skill's territory.

Subscribe to the project's GitHub security advisories, and re-read that list before every upgrade.

## 5. Compose variants and generating the environment

Two compose files ship, and they differ in a way that surprises people:

| File | Database |
|---|---|
| the quickstart compose | a **single container** with embedded Postgres — simpler for one tenant |
| the main compose | an external `postgres:17-alpine` service |

A systemd `quadlet/` directory also ships if you prefer native systemd over Compose.

Generate the secrets without ever displaying them:

```bash
if [ ! -f .env ]; then umask 077; {
  echo "BETTER_AUTH_SECRET=$(openssl rand -hex 32)";
  echo "PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$(openssl rand -hex 32)";
} > .env; chmod 600 .env; fi
```

Required environment in full: `BETTER_AUTH_SECRET`, `PAPERCLIP_TOOL_ACTION_SIGNING_SECRET`,
`PAPERCLIP_DEPLOYMENT_MODE`, `PAPERCLIP_DEPLOYMENT_EXPOSURE`, `PAPERCLIP_PUBLIC_URL`,
`PAPERCLIP_ALLOWED_HOSTNAMES`, `PAPERCLIP_BIND`.

## 6. Operating it from a shell: the CLI is source-only

No compiled CLI ships in the image, but `tsx` does, so it runs straight from source:

```bash
docker exec -i <container> bash -s <<'EOS'
export PAPERCLIP_HOME=/paperclip
node --import /app/server/node_modules/tsx/dist/loader.mjs /app/cli/src/index.ts --help
EOS
```

Command surface includes `company create`, `agent create --json` (non-interactive), `agent hire`,
`token board|agent`, `join list|approve|claim-key`, `whoami`, `health`, `doctor`, `env`, and a full
`openapi` dump. Point `--data-dir` / `PAPERCLIP_HOME` at the mounted volume so CLI context survives
container recreation.

**The one step that needs a human:** the interactive connect command refuses to be scripted, so a
board token has to come from an interactive approval flow or be handed over deliberately. Plan for
exactly one operator click.

> Do not fabricate a token to work around this, and do not try to complete agent onboarding from an
> agent session alone. Hand the operator the exact field values (see
> `references/hermes-gateway-adapter.md`) and let them do that single step.

## 7. Read the adapter's own documentation, and know which listener you are pointing at

The authoritative field spec is compiled into the image at
`/app/server/dist/adapters/hermes-gateway-doc.js` — read it rather than inferring field names.

One trap in it: the doc also quotes **dashboard-style** bases (e.g. a `:9119` listener with `/chat`)
which it maps onto `/api`. The `/api/health` + `/api/v1/runs` pair belongs to the *dashboard*
listener, not the API server. Confirm which one you are configuring by probing both endpoints:

```bash
curl -s -o /dev/null -w '%{http_code}\n' <base>/health     # expect 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST <base>/v1/runs   # expect 400, not 404
```

A 400 on an empty body means the route exists and validated the payload. A 404 means wrong base or
wrong prefix.

## 8. How an agent reaches Paperclip — local vs non-local

This distinction causes a specific, expensive failure: an agent that cannot authenticate does not
stop, it goes looking for a way in — reading files, logs and its own skill docs — which burns tokens
on every heartbeat. One stuck agent measured roughly **113,000 input tokens per call** while flailing.

| Adapter kind | Paperclip API URL | `PAPERCLIP_API_KEY` |
|---|---|---|
| **Local** (`claude_local`, `codex_local`, `opencode_local`, `process`, …) | the default `http://127.0.0.1:3100` is **correct** — the agent runs on Paperclip's own machine | **auto-injected** as a short-lived run JWT. Set nothing. |
| **Non-local** (`hermes_gateway`, `openclaw_gateway`, `http`, …) | must be an address reachable **from the agent's host** | **not injected — the operator must set it**, in the agent's secrets/variables |

So: an agent that lives elsewhere needs both boxes filled, and an agent that lives inside needs
neither. The prefilled `127.0.0.1:3100` is a trap when reused for an outside agent — it means *"this
same machine"*, and Paperclip is not on that machine.

Verify from the agent's own host before blaming anything else:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<paperclip-host>/api/health   # expect 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3100/api/health      # 000 = nothing there
```

**Approval prompts expire.** When a run trips a security prompt and nobody answers, it is cancelled
with *"the user has NOT consented… Silence is not consent"* and the agent moves on. Watch for prompts
while an agent is working, or the run dies quietly.

## 9. Agent fields that are not editable after creation

- **`role`** renders as plain text in the UI. Its valid values are a fixed set (`ceo`, `cto`, `cmo`,
  `cfo`, `security`, `engineer`, `designer`, `pm`, `qa`, `devops`, `researcher`, `general`). There is
  no database constraint, but the app expects a known value — use `role` for the category and
  **`title`** (free text) for the human job title.
- **Budgets are policies, not a field.** They live in a `budget_policies` table keyed by
  `scope_type`/`scope_id`, with `amount` in cents, a `window_kind`, and `hard_stop_enabled`. With no
  policy rows the UI reports *"Unlimited budget"*. A zero budget does not mean "no spend" — it means
  nothing stops the agent.

**Reading the database** (the image ships no `psql`; use the app's own `pg` module and the
embedded-postgres defaults on port 54329):

```bash
docker exec <container> node -e '
  const {Client}=require("/app/node_modules/.pnpm/pg@8.18.0/node_modules/pg");
  const c=new Client({host:"127.0.0.1",port:54329,user:"paperclip",password:"paperclip",database:"paperclip"});
  c.connect().then(()=>c.query("select name,role,title,status from agents")).then(r=>{console.log(r.rows);c.end()});'
```

Read freely; anything that **writes** should be snapshotted first and verified by reading back.
