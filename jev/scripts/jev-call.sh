#!/usr/bin/env bash
# Call TypeSafe Jev (POST /v1/systemone). Resolves the API key from TYPESAFE_API_KEY when it is
# exported, otherwise from the Hermes .env of the active profile (then the global one, then any
# profile that defines it, with a warning). The key is never echoed, never logged and never put
# in curl's argv -- it reaches curl on stdin via -K.
#
# Usage: jev-call.sh ['<json request body>']
set -euo pipefail

warn() { printf '%s\n' "jev-call: $*" >&2; }

PROFILE="${HERMES_PROFILE:-${HERMES_SESSION_PROFILE:-}}"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"

read_key() {  # read_key <file> -> prints a usable key, or nothing
  [ -f "$1" ] || return 1
  local v
  v="$(grep -m1 -E '^TYPESAFE_API_KEY=' "$1" | cut -d= -f2- || true)"
  [ -n "${v:-}" ] || return 1
  v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
  case "$v" in
    ""|"<"*|*"your_key"*|*"paste"*|*"REDACTED"*) return 1 ;;  # placeholder, not a credential
  esac
  printf '%s' "$v"
}

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  files=("$HERMES_ROOT/.env")
  [ -n "$PROFILE" ] && files+=("$HERMES_ROOT/profiles/$PROFILE/.env" "$HOME/.hermes/profiles/$PROFILE/.env")
  files+=("$HOME/.hermes/.env")
  shopt -s nullglob
  files+=("$HOME/.hermes/profiles/"*"/.env")

  key=""; src=""; others=()
  for f in "${files[@]}"; do
    v="$(read_key "$f" || true)"
    [ -n "$v" ] || continue
    if [ -z "$key" ]; then key="$v"; src="$f"; else others+=("$f"); fi
  done

  if [ -z "$key" ]; then
    warn "no usable TYPESAFE_API_KEY in the environment or any Hermes .env"
    warn "mint one at https://console.typesafe.ai/keys and add 'TYPESAFE_API_KEY=<key>' to your profile .env"
    exit 2
  fi
  [ "${#others[@]}" -gt 0 ] && warn "TYPESAFE_API_KEY is also set in: ${others[*]} (using $src)"
  export TYPESAFE_API_KEY="$key"
fi

default_body='{"state":"ping","model":"jev-latest","questions":{"ok":{"type":"noul","instructions":"Is this text a short greeting?"}}}'
body="${1:-$default_body}"

printf 'header = "Authorization: Bearer %s"\n' "$TYPESAFE_API_KEY" | \
  curl -sS -K - -X POST "https://api.typesafe.ai/v1/systemone" \
    -H 'Content-Type: application/json' \
    --fail-with-body --max-time 60 \
    -d "$body"
echo
