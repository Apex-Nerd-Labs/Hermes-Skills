#!/usr/bin/env bash
# Re-pull the upstream TypeSafe skill and compare its git blob sha1 with the one recorded in
# this skill's frontmatter. A mismatch means upstream changed: read the diff and re-apply the
# rename + header before syncing.
set -euo pipefail

URL="https://raw.githubusercontent.com/typesafe-ai/skills/main/skills/typesafe-ai/SKILL.md"
SKILL_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sS --fail --max-time 30 -o "$TMP/upstream.md" "$URL"

# sanity: this must look like the skill we know, not an error page or a captive portal
[ "$(head -1 "$TMP/upstream.md")" = "---" ] \
  || { echo "aborting: payload has no frontmatter" >&2; exit 1; }
grep -q '^name: typesafe-ai' "$TMP/upstream.md" \
  || { echo "aborting: payload is not the typesafe-ai skill" >&2; exit 1; }

got="$(printf 'blob %s\0' "$(wc -c < "$TMP/upstream.md")" | cat - "$TMP/upstream.md" | sha1sum | cut -d' ' -f1)"
have="$(grep -m1 -o 'upstream_git_blob_sha1: [0-9a-f]\{40\}' "$SKILL_DIR/SKILL.md" | awk '{print $2}' || true)"

echo "upstream now : $got"
echo "recorded here: ${have:-<none>}"
if [ "$got" = "${have:-}" ]; then
  echo "MATCH - upstream unchanged"
else
  echo "MISMATCH - review the diff, re-apply the rename + header, then re-sync"
  exit 1
fi
