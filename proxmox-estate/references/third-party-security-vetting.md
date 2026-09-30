# Third-Party Platform Security Vetting

Run this before choosing where anything lands. The deliverable is a severity table plus a placement
decision — not a verdict of "seems fine".

## 1. Published advisories — the fastest read on the real threat model

```bash
curl -s "https://api.github.com/repos/<owner>/<repo>/security-advisories" | python3 -c "
import sys,json
for a in json.load(sys.stdin):
    print(a['ghsa_id'], a['severity'], a['published_at'], '|', a['summary'][:110])"
```

Then fetch the ones that matter individually (`/security-advisories/<GHSA-ID>`) for the
reproduction detail and the `patched_versions` / `vulnerable_version_range` in `vulnerabilities[]`.

A published, versioned, fixed advisory is a *positive* signal — it means there is a response
process. What matters is the **shape** of what they had to fix:

- Advisories against the **default** configuration are the worst kind: the default is exactly what a
  fast install produces.
- **Repeat findings in the same subsystem** mean it is not sound yet, whatever the patch says.
  Recurring cross-tenant/authorization-IDOR findings mean multi-tenant isolation cannot be trusted
  yet, regardless of what the feature list claims — do not put client tenants in it.
- Findings phrased "unauthenticated", "drive-by", or "via DNS rebinding" tell you the project
  expects to be reachable by more than its operator, and must never be internet-exposed.
- Findings in the class "the agent picked up a credential from another app on the same host" are
  architecture-level, not bugs. They will not be fixed by upgrading. See section 4.

## 2. Deployment modes and defaults

Read the deployment-modes documentation, not the README. Establish:

- The default mode, and whether it authenticates at all.
- Whether signup is open — self-registration with no invite or email verification is an
  authentication-bypass multiplier that turns an authz bug into unauthenticated RCE.
- How the bind preset works (`loopback` / `lan` / `tailnet` / `public`) and whether there is an
  allowed-hostnames allowlist to populate for private aliases.

Then pin: **authenticated + private exposure**, bound to explicit addresses, allowed-hostnames set.
Never the no-auth default, never public.

## 3. Execution surface

Ask what the process can *execute*, not what the UI displays:

- Agent/CLI adapters that spawn subprocesses, generic shell adapters, provision/cleanup command
  fields, workspace git operations, plugin/skill installation.
- Exposed Docker sockets or published Docker API ports in the target guest. Port 2375 has no TLS —
  Docker's own documentation equates it to unrestricted root. 2376 is the TLS port.
- Stored credential stores in the same guest: automation/CI UIs, tunnel clients, dashboards.
- Package/binary install paths that fetch from the network at runtime.

## 4. The credential-inheritance rule (the decisive one)

Local adapters inherit the ambient environment and filesystem of the container they run in. A
platform that spawns agents as the container user can read **everything** that user can read,
including credentials the operator never granted it. This is not theoretical: the canonical advisory
in this class is "the agent silently picked up a token belonging to another app on the same host and
used it to act in the real world".

Therefore the only safe host is a guest whose ambient credential surface is **empty**. Enumerate and
disqualify:

| Item | Why it disqualifies |
|---|---|
| `/var/run/docker.sock` | Root-equivalent on the guest |
| Published Docker API port (2375) | Unauthenticated root over the API |
| Reverse-tunnel / remote-access client | Credentials granting ingress to the whole estate |
| Browser terminal, container dashboard with exec | Interactive shell as the guest user |
| Automation UI (Ansible/CI) holding SSH secrets | Unrestricted lateral movement |
| Co-resident database server | Direct data access |

Put the new platform in its own guest and give it its **own** provider keys — never the fleet's.

## 5. Reporting shape

Lead with the bottom line (deploy / do not / deploy with limits), then a severity table of the
advisories that actually matter, then the placement decision and its reason. Name unrelated findings
you tripped over as separate work items rather than burying them in the body.
