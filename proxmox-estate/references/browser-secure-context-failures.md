# Browser Failures Caused by a Non-Secure Origin

Plain HTTP on a non-loopback host is not merely "unencrypted". Browsers withhold entire APIs and
silently drop cookies, which surfaces as application bugs. Diagnose the origin before debugging the
app.

## Symptom → cause → fix

| Symptom | Mechanism | Fix |
|---|---|---|
| `crypto.randomUUID is not a function` (or another `window.crypto` call throwing) during setup | Secure-context-only API. The origin is plain HTTP on a non-localhost host, so the function is `undefined`. | Serve the app over HTTPS. Do not guard the call site in a vendored build — the app needs TLS anyway. |
| Login appears to succeed, then immediately bounces; API returns `403` after a `200` sign-in | The session cookie is marked `Secure` and the browser refuses to store it on an insecure origin. | Move the user to the HTTPS origin. Nothing else is wrong — the credentials were accepted. |
| Feature works for the admin but not for a second user | Origin-specific cookies: each origin has its own cookie jar, so an HTTP session does not migrate to HTTPS. | Expect one re-login when the canonical origin changes. |

## Detecting which origin a user is actually on

Do this FIRST when a browser-side auth or API failure is reported. Application request logs usually
record the browser's `Origin` and `Referer`, which identify the tab the user is in — often more
informative than anything the user can describe:

```bash
docker logs --tail 400 <app> | grep -o '"origin":"[^"]*"'  | sort -u
docker logs --tail 400 <app> | grep -o '"referer":"[^"]*"' | sort -u
```

A `200` sign-in followed by `401` on the very next authenticated call, with an `http://` origin, is
the cookie case. A wrong hostname in the `Referer` is a routing case — different machine, different
app, hence the `404`.

## Why a canonical-URL setting changes cookie behaviour

Framework auth layers commonly derive cookie security from the configured public/base URL. The
typical logic: if the configured public URL starts with `http://`, secure cookies are disabled so
plain-HTTP LAN access keeps working; once it is `https://`, secure cookies are enabled.

So flipping the canonical URL to HTTPS **is** the change that breaks existing plain-HTTP logins. Enforce
one of two consistent states rather than mixing them:

- canonical URL HTTPS + browsers reach it over HTTPS (correct), or
- canonical URL HTTP + everything cleartext (only for an isolated lab).

Record which one an instance is in, because the ports will still serve pages either way, which makes
the wrong state look like a broken app.

## Confirming a secure-context diagnosis

Do not pattern-match on the error text alone. Confirm the mechanism:

```bash
# the server-side runtime is fine — the fault is the browser context
docker exec <app> node -e "console.log('crypto.randomUUID:', typeof require('node:crypto').randomUUID, '| globalThis.crypto:', typeof globalThis.crypto)"
```

If the runtime has the function and only the browser throws, it is a context problem, not a missing
dependency or a bad build.
