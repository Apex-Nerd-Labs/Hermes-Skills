# The `hermes_gateway` adapter — contract

Paperclip ships built-in adapter types for the runtimes it knows about. The authoritative field
spec is compiled into the server image; read it there rather than guessing:

```bash
docker exec <container> cat /app/server/dist/adapters/hermes-gateway-doc.js
docker exec <container> cat /app/server/dist/adapters/builtin-adapter-types.js
```

`hermes_gateway` is in the built-in roster, alongside `claude_local`, `codex_local`,
`gemini_local`, `grok_local`, `kimi_local`, `opencode_local`, `cursor*`, `pi_local`, `acpx_local`,
`paperclip_runner`, `openclaw_gateway`, and a generic `process` shell adapter.

---

## Choosing between the two Hermes adapters

| | `hermes_local` | **`hermes_gateway`** |
|---|---|---|
| What it runs | the `hermes` CLI as a **child process inside the Paperclip container** | calls an **already-running** Hermes API server over HTTP/SSE |
| Requires | Hermes installed and authenticated inside that container | a reachable API server plus a key |
| Gives you | a fresh agent — **no persona, skills, or memory** | your real, configured profile |
| Use when | Paperclip and Hermes genuinely share one trusted host | almost always, and always when you want a specific profile |

The adapter's own README states the rule: choose `hermes_local` when Paperclip and Hermes run on
the same trusted host. In a containerised deployment they usually do not.

---

## Required payload

An agent hire/join payload carrying `agentDefaultsPayload`:

```json
{
  "requestType": "agent",
  "agentName": "<your agent name>",
  "adapterType": "hermes_gateway",
  "capabilities": "Hermes gateway agent",
  "agentDefaultsPayload": {
    "apiBaseUrl": "https://<hermes-host>:<port>/p/<profile>",
    "apiKey": "<that profile's API_SERVER_KEY>",
    "paperclipApiUrl": "https://<paperclip-host>"
  }
}
```

| Field | Required | Notes |
|---|---|---|
| `apiBaseUrl` | yes | Base URL of the Hermes API server **as reachable from the Paperclip server**. A dashboard-root style URL is accepted and mapped to its API base automatically. **No `/v1` suffix** — the adapter appends it. |
| `apiKey` | yes | The Hermes API server key, matching that profile's `API_SERVER_KEY`. This is the **Hermes** key, not the Paperclip agent token. |
| `paperclipApiUrl` | strongly recommended | The Paperclip base URL **as reachable from Hermes**, used for invite, claim, skill bootstrap, and later callbacks. |
| `timeoutSec` / `timeoutMs` | optional | Per-run request timeout, when the installed adapter honours it. |

Both parties must be able to reach each other. If the Paperclip host has an access allowlist, add
the Hermes host's name to it.

---

## What the adapter probes

| Purpose | Request |
|---|---|
| Reachability / health | `GET <apiBaseUrl>/health` → expect **200** |
| Starting runs | `POST <apiBaseUrl>/v1/runs` → expect **400 on an empty body** if the route exists |

> **A 400 is success here.** It means the route exists and validated the payload. A **404** means
> the wrong host or the wrong profile prefix.

Verify both before wiring, from **inside the Paperclip container** — that is the vantage point
whose DNS and TLS trust actually matter:

```bash
docker exec <container> curl -s -o /dev/null -w '%{http_code}\n' \
  https://<hermes-host>:<port>/p/<profile>/health
docker exec <container> curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://<hermes-host>:<port>/p/<profile>/v1/runs
```

---

## Hermes side: enabling the API server

```bash
hermes config set platforms.api_server.enabled true
hermes config set platforms.api_server.host <tailnet-ip>    # tailnet only; never 0.0.0.0
hermes config set platforms.api_server.port 8642
```

Bind the **tailnet/private address**, not all interfaces: the endpoint dispatches work that has
tool access, so it must not be internet-facing.

Then one restart, because a multiplexed gateway serves every profile from one process:

```bash
hermes gateway restart
```

### Profile routing under multiplexing

The default profile owns the single HTTP listener; other profiles are served as
`/p/<profile>/<path>` on that listener. Two consequences:

1. `/v1/models` on the **root** returns the *default* profile's model; `/p/<profile>/v1/models`
   returns that profile's. Use that to confirm you are talking to the profile you think you are.
2. The bearer token verified for `/p/<profile>/…` is that **profile-scoped** `API_SERVER_KEY`, not
   the default's. Non-default profiles enforce a minimum key length (16 characters).

---

## Network topologies

| Situation | `apiBaseUrl` |
|---|---|
| Same host, loopback | `http://127.0.0.1:8642` (plain HTTP is permitted for loopback only) |
| Private LAN | `http://<lan-ip>:8642` — but see the HTTPS rule below |
| Private overlay (Tailscale/WireGuard) with TLS front | `https://<hermes-host>:<port>/p/<profile>` |
| Containerised Paperclip, Hermes on the host | `http://host.docker.internal:8642` |
| Both in the same compose network | `http://hermes:8642` |
| Behind a reverse proxy | `https://<hermes-fqdn>` with the origin still requiring the key |

**Plain HTTP is refused for any non-loopback host.** For remote deployments, terminate TLS — a
private overlay's own certificate is a real certificate, so nothing is being bypassed.

If the API server binds only one address, a local TLS-terminating proxy must target **that**
address; `127.0.0.1` will be refused.

---

## Operational notes

- **Waking cost is dominated by the profile's own system prompt and tooling.** A large persona
  measured ~20,000 input tokens for a trivial request. Budget heartbeat intervals accordingly.
- **The API server is unsandboxed by default.** Hermes warns on startup that dispatched work "runs
  as the host user with full terminal/file access". Set `terminal.backend: docker` for that profile,
  or use a dedicated, narrowly-scoped profile rather than a privileged one.
- **Treat `API_SERVER_KEY` as a credential.** It authorises agent execution on the Hermes host.
  Store it in `.env` (mode 600), never in a repo, and rotate it if it is ever pasted anywhere
  unexpected.
- **After wiring, confirm with a real turn,** not just a health check: send a short prompt through
  `<apiBaseUrl>/v1/chat/completions` with the key and check you get a completion back.
