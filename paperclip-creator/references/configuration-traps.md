# Configuration traps — symptom → cause → fix

Every entry below was hit in a real deployment and traced to source. Generic throughout: no
hostnames, addresses, or organisation details.

---

## T1 — "Couldn't connect" testing a Hermes Gateway agent

**Symptom**

> Couldn't connect — Check your model and provider connection, then try again.
> *Test details:* `Hermes gateway apiBaseUrl uses remote plain HTTP for '<host>'. Use HTTPS or set
> dangerouslyAllowInsecureRemoteHttp=true only for unsafe local development.`

**Cause** The `hermes_gateway` adapter refuses `http://` to any non-loopback host. Loopback `http`
stays allowed. This is a sensible guardrail, not a bug.

**Fix** Give the Hermes API server real TLS rather than disabling the check:

```bash
tailscale serve --bg --https=<free-port> http://<api-server-host>:8642
```

Then use `https://<hermes-host>:<free-port>/p/<profile>` as the base URL.

**Do not** set `dangerouslyAllowInsecureRemoteHttp=true`. The adapter's own message calls it unsafe
local development only.

**Confirm** `curl -s -o /dev/null -w '%{http_code}\n' https://<hermes-host>:<port>/p/<profile>/health` → `200`.

---

## T2 — `crypto.randomUUID is not a function`

**Symptom** The agent connection test succeeds, then a red error appears under the form.

**Cause** `window.crypto.randomUUID` exists **only in a secure context**. Serving the UI over plain
`http://` on a non-loopback host makes it `undefined`. Paperclip calls it unguarded at
`ui/src/lib/provider-credential.ts`, which is the file that stores the agent credential — so the
error fires exactly when saving.

Every sibling call site in the same codebase guards the call (e.g. `ui/src/lib/cross-tab-poll.ts`,
`ui/src/lib/issue-execution-policy.ts`, `ui/src/components/task-chat/RunnerGoalWidget.tsx`), which
is how you can tell the unguarded one is an oversight rather than intent. Worth reporting upstream.

**Fix** Serve the UI over HTTPS. Nothing else.

**Confirm** Open the HTTPS origin and repeat the agent setup.

---

## T3 — Login returns 200, then the very next request is 401/403

**Symptom** Correct credentials, but the page bounces back to login.

**Log signature**

```
POST /api/auth/sign-in/email  -> 200  (sets a cookie)
GET  /api/auth/get-session    -> 401
GET  /api/companies           -> 403
```

**Cause** A `Secure` cookie dropped by the browser. Paperclip derives cookie security from
`PAPERCLIP_PUBLIC_URL` (`server/src/auth/better-auth.ts`):

```js
if (publicUrl) return publicUrl.startsWith("http://");   // -> disableSecureCookies
```

- `PUBLIC_URL` starts with `http://` → secure cookies **disabled** → `http://` login works.
- `PUBLIC_URL` is `https://…` → secure cookies **enabled** → the browser silently refuses to store
  the cookie on an `http://` origin. Sign-in returns 200; the session dies immediately.

So this triggers the moment you move the canonical URL to HTTPS — which you should.

**Fix** Use the HTTPS origin, and only the HTTPS origin.

**Diagnostic trick** The server logs the browser's `origin` and `referer` on every request. Read
those before theorising about credentials — they tell you exactly which URL the user is actually on:

```bash
docker logs --tail 400 <container> | grep -o '"origin":"[^"]*"' | sort -u
```

---

## T4 — "org non existent" / "No company matches prefix"

**Cause** The first path segment of every UI route is the organisation's `issuePrefix`. A segment
matching no organisation renders that message instead of a 404.

**Derivation** (`server/src/services/issue-prefix.ts`):

```js
const normalized = name.toUpperCase().replace(/[^A-Z]/g, "");
return normalized.slice(0, 3) || ISSUE_PREFIX_FALLBACK;
```

Uppercase, strip non-letters, take three. `"Acme Widgets"` → `ACW`. Collisions get `A`, `AA`… The
fallback when nothing resolves is `PAP`.

**Fix** Use the correct prefix, or navigate from the UI root. Never guess it — read the derivation
and the organisation's name.

---

## T5 — `404: Not Found` / bare `not found`

**Cause** Wrong hostname. On a multi-service tailnet it is easy to send an app's path to a
*different* node that happens to serve something else at its root.

**Fix** Confirm which node serves the instance, and that the path prefix belongs to it:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<host>/            # app root
curl -s -o /dev/null -w '%{http_code}\n' https://<host>/<PREFIX>/agents
```

---

## T6 — Health check fails on `127.0.0.1`

**Cause** Compose publishes only the addresses you listed. Loopback is deliberately not published.

**Fix** Test against a published address:

```bash
curl -s http://<published-ip>:3100/api/health
```

---

## T7 — A false "BUILD_ERROR" from monitoring

**Cause** Grepping the build log for `ERROR` matches **echoed Dockerfile commands**. The Dockerfile
contains:

```dockerfile
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)
```

BuildKit prints that command line verbatim, so a naive grep fires on a perfectly healthy build.

**Fix** Match real BuildKit failure markers only, and detect success by artefact:

```bash
grep -aE '^#[0-9]+ ERROR:|failed to solve:|did not complete successfully' <log>
docker images -q <image> | wc -l        # 1 == built
```

---

## T8 — Config change appears to be ignored

**Cause** `.env` values are read at **process start**, so a running gateway never sees a newly
added key. Also, under multiplexing one gateway service serves every profile — a restart affects
all of them.

**Fix** One deliberate restart, then confirm every profile is served:

```bash
hermes gateway restart
hermes gateway list
```

Avoid several restarts within a few minutes: chat-platform adapters can stop delivering guild
events after rapid reconnects.

---

## T9 — A secret field rejects a "correct-looking" value

**Cause** Human error copying from a long `.env`. Adjacent keys look alike — a dashboard basic-auth
secret sitting a few lines below the API key is an easy grab, and the field will accept it and fail
to authenticate.

**Fix** Extract exactly one value:

```bash
grep -m1 '^API_SERVER_KEY=' <path-to>/.env | cut -d= -f2-
```

Sanity-check length and prefix/suffix before pasting. Treat any secret pasted into a web form as
spent: rotate it.

---

## T10 — Disk fills during the build

**Cause** A large dependency graph on a modest rootfs — Rust toolchain, several npm CLI toolchains,
and a multi-gigabyte build cache.

**Fix**

```bash
docker system df
docker builder prune -f     # builds stay reproducible from the pinned tag
```

Long term, watch the **data directory** (agent workspaces), not the image.

---

## T11 — Reusing an existing container goes wrong

**Symptom** After co-locating the platform with an existing service, unexpected credential access
or a startling blast radius.

**Cause** An agent orchestrator spawns child processes that inherit the container's entire
filesystem and environment. Any credential present in that container becomes *its* credential —
docker sockets, reverse-tunnel configs, automation credential stores, mail tokens. Upstream
advisories exist precisely because a local adapter inherited a host-connected credential it was
never granted.

**Fix** Give the platform its own container. If you must share, the container must be
credential-sterile first. Ask of every candidate: *what can this service already reach?*

---

## T12 — Instance unreachable, everything looks healthy

Work outwards; the last step is the one people forget:

```bash
# guest running?            pct status <ctid>
# container running?        docker ps
# listening?                ss -tlnp | grep <port>
# app answering?            curl -s https://<host>/api/health
# proxy intact?             tailscale serve status
# can the app reach Hermes? docker exec <container> curl -s -o /dev/null -w '%{http_code}\n' \
                              https://<hermes-host>:<port>/p/<profile>/health
```

With the platform healthy, the remaining failure is almost always name resolution or TLS trust from
**inside** the container.
