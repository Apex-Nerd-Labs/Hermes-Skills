# Tailnet HTTPS Exposure with `tailscale serve`

Why: services on a tailnet still need real TLS. Clients frequently refuse plain HTTP to a
non-loopback host, browsers withhold secure-context APIs and `Secure` cookies, and a management API
should not be reachable in cleartext. `tailscale serve` terminates TLS with a genuinely trusted
certificate for the node's MagicDNS name — no self-signed CA, no client-side TLS bypass.

## Prerequisites

HTTPS certificates must be enabled for the tailnet. Confirm before planning around it:

```bash
tailscale status --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('Self',{}).get('DNSName'), d.get('CertDomains'))"
```

If `CertDomains` is empty, HTTPS is not enabled for the tailnet and `serve` will not issue a cert.

## Recipe

```bash
# 1. Know what is already listening and what is already mapped
tailscale serve status
# 2. Pick an UNUSED HTTPS port. 443 / 8443 / 8444 are commonly taken by other services.
#    Do not reuse one, and do not repoint an existing mapping.
# 3. Point the proxy at an address the service ACTUALLY binds.
tailscale serve --bg --https=<free-port> http://<service-bind-ip>:<port>
# 4. Re-read the mapping table and confirm the others are untouched
tailscale serve status
```

## Choosing the serve target

This is the detail that silently breaks the setup.

| Service binds | Correct target | Wrong target |
|---|---|---|
| `127.0.0.1:PORT` only | `http://127.0.0.1:PORT` | the tailnet IP (nothing listening) |
| A specific tailnet/LAN IP | `http://<that-ip>:PORT` | `http://127.0.0.1:PORT` |
| `0.0.0.0:PORT` | either works | — |

A service configured to bind one specific overlay address will refuse loopback. Check with
`ss -tlnp | grep <port>` rather than assuming, and remember that a container publishing a port to
specific host addresses does **not** make it reachable on the host's loopback.

## Verifying

Verify from the **far side** — another machine, and ideally from inside the client's own container or
network namespace. Name resolution and certificate trust are what fail there, not reachability.

```bash
HOST=<node>.<tailnet>.ts.net
curl -s -o /dev/null -w 'health   %{http_code}\n'          "https://$HOST:<port>/<health-path>"
curl -s -o /dev/null -w 'auth ok  %{http_code}\n' -H "Authorization: Bearer $KEY"   "https://$HOST:<port>/<authed-path>"
curl -s -o /dev/null -w 'auth bad %{http_code}\n' -H 'Authorization: Bearer wrong'   "https://$HOST:<port>/<authed-path>"
curl -s -o /dev/null -w 'tls      %{http_code} verify=%{ssl_verify_result}\n'        "https://$HOST:<port>/<health-path>"
```

`ssl_verify_result=0` means the chain validated. A `000` immediately after starting the proxy is a
startup race, not a failure — retry several times before concluding anything, and never report a
result you only saw once.

Where the client runs in a container of its own, prove resolution there too:

```bash
docker exec <client> getent hosts "$HOST"
docker exec <client> curl -s -o /dev/null -w '%{http_code}\n' "https://$HOST:<port>/<health-path>"
```

## Coexistence — adding a mapping must not disturb the others

```bash
tailscale serve status
for p in 443 8443 8444; do echo "$p -> $(curl -s -o /dev/null -m 8 -w '%{http_code}' https://$HOST:$p/)"; done
```

## Multiple services, one node

Give each service its own HTTPS port rather than mounting them under path prefixes. Path-prefix
proxying has to preserve or strip the prefix in a way the backend agrees with, which adds a failure
mode to save a port number.
